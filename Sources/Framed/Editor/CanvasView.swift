import AppKit

enum EditorCommand {
    case copy, save, close
}

/// Interactive editing surface, drawn over the editor's background. Fits the visible region
/// (the crop, or the whole image while cropping) between the title bar and the dock, turns mouse
/// input into annotations, lets the Select tool move/resize them, and handles editor shortcuts.
final class CanvasView: NSView, NSTextFieldDelegate {
    /// Space kept clear for the title bar and the floating dock.
    static let insets = NSEdgeInsets(top: 60, left: 28, bottom: 92, right: 28)

    let document: EditorDocument
    var onCommand: (EditorCommand) -> Void = { _ in }

    private enum Gesture {
        case draw(origin: CGPoint)
        case crop(origin: CGPoint)
        case cropResize(original: CGRect, edges: CropEdges, start: CGPoint)
        case move(original: Annotation, start: CGPoint)
        case handle(original: Annotation, index: Int)
    }

    private var gesture: Gesture?
    private var liveEditStarted = false
    private var draft: Annotation?
    private var cropDraft: CGRect?
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    /// The text annotation being re-edited, hidden while its field is open.
    private var editingTextID: UUID?

    init(document: EditorDocument) {
        self.document = document
        super.init(frame: .zero)
        observeDocument()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Leaves the title bar strip to the window so it can still be dragged.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return local.y < Self.insets.top - 8 ? nil : super.hitTest(point)
    }

    /// Redraws whenever document state, the tool, the selection or the style changes.
    private func observeDocument() {
        withObservationTracking {
            _ = document.state
            _ = document.tool
            _ = document.selectedID
            _ = document.pendingCrop
            _ = document.color
            _ = document.size
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if ![.text, .select].contains(self.document.tool) { self.endTextEditing() }
                self.styleTextField()
                self.needsDisplay = true
                self.refreshCursor()
                self.observeDocument()
            }
        }
    }

    // MARK: Coordinate mapping

    private var region: CGRect { document.tool == .crop ? document.imageBounds : document.state.crop }

    /// Image points → view points. Scales the region (up or down) to fill the free area, keeping its aspect ratio.
    private var transform: CGAffineTransform {
        let region = region
        let i = Self.insets
        let available = CGRect(x: i.left, y: i.top, width: bounds.width - i.left - i.right, height: bounds.height - i.top - i.bottom)
        guard region.width > 0, region.height > 0, available.width > 0, available.height > 0 else { return .identity }
        let zoom = min(available.width / region.width, available.height / region.height)
        let origin = CGPoint(x: (available.midX - region.width * zoom / 2).rounded(), y: (available.midY - region.height * zoom / 2).rounded())
        return CGAffineTransform(translationX: origin.x, y: origin.y)
            .scaledBy(x: zoom, y: zoom)
            .translatedBy(x: -region.minX, y: -region.minY)
    }

    private var zoom: CGFloat { transform.a }

    private func imagePoint(_ event: NSEvent, clamped: Bool = true) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil).applying(transform.inverted())
        guard clamped else { return p }
        let r = region
        return CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let transform = transform
        let card = region.applying(transform)
        let cardPath = CGPath(roundedRect: card, cornerWidth: 10, cornerHeight: 10, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -24), blur: 60, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.addPath(cardPath)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()
        ctx.concatenate(transform)
        ctx.interpolationQuality = .high
        document.drawContent(in: ctx, draft: draft, hiding: editingTextID)
        ctx.restoreGState()

        ctx.addPath(cardPath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.07).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        if document.tool == .crop { drawCropOverlay(card: card, in: ctx) }
        if document.tool == .select, let selected = document.selected { drawSelection(selected, in: ctx) }
    }

    private func drawCropOverlay(card: CGRect, in ctx: CGContext) {
        let crop = (cropDraft ?? document.visibleCrop).applying(transform)
        let dim = CGMutablePath()
        dim.addRect(card)
        dim.addRect(crop)
        ctx.addPath(dim)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [5, 4])
        ctx.stroke(crop.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()

        // Grab handles: L-shaped corners and short bars at the middle of each side.
        let arm = min(18, crop.width / 3, crop.height / 3)
        let handles = CGMutablePath()
        for (x, y, sx, sy) in [(crop.minX, crop.minY, 1.0, 1.0), (crop.maxX, crop.minY, -1.0, 1.0),
                               (crop.maxX, crop.maxY, -1.0, -1.0), (crop.minX, crop.maxY, 1.0, -1.0)] {
            handles.addLines(between: [CGPoint(x: x + sx * arm, y: y), CGPoint(x: x, y: y), CGPoint(x: x, y: y + sy * arm)])
        }
        handles.move(to: CGPoint(x: crop.midX - arm / 2, y: crop.minY)); handles.addLine(to: CGPoint(x: crop.midX + arm / 2, y: crop.minY))
        handles.move(to: CGPoint(x: crop.midX - arm / 2, y: crop.maxY)); handles.addLine(to: CGPoint(x: crop.midX + arm / 2, y: crop.maxY))
        handles.move(to: CGPoint(x: crop.minX, y: crop.midY - arm / 2)); handles.addLine(to: CGPoint(x: crop.minX, y: crop.midY + arm / 2))
        handles.move(to: CGPoint(x: crop.maxX, y: crop.midY - arm / 2)); handles.addLine(to: CGPoint(x: crop.maxX, y: crop.midY + arm / 2))
        ctx.addPath(handles)
        ctx.setStrokeColor(.white)
        ctx.setLineWidth(4)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.strokePath()
    }

    private func drawSelection(_ annotation: Annotation, in ctx: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        let outline = annotation.bounds.applying(transform).insetBy(dx: -4, dy: -4)
        ctx.saveGState()
        ctx.setStrokeColor(accent)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(outline.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()

        for handle in annotation.handles.map({ $0.applying(transform) }) {
            let box = CGRect(x: handle.x - 4.5, y: handle.y - 4.5, width: 9, height: 9)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.setFillColor(.white)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.5)
            ctx.drawPath(using: .fillStroke)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        endTextEditing()
        needsDisplay = true
    }

    // MARK: Cursor

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: event.locationInWindow) }

    /// Re-evaluates the cursor without a mouse event, e.g. after a keyboard tool switch.
    private func refreshCursor() {
        guard let window, window.isKeyWindow, gesture == nil else { return }
        let location = window.mouseLocationOutsideOfEventStream
        if bounds.contains(convert(location, from: nil)) { updateCursor(at: location) }
    }

    private func updateCursor(at windowPoint: CGPoint) {
        let p = convert(windowPoint, from: nil).applying(transform.inverted())
        let overImage = region.contains(p)
        switch document.tool {
        case .select:
            let overHandle = handleIndex(at: p) != nil
            let overAnnotation = document.annotation(at: p, tolerance: 4 / zoom) != nil
            (overHandle ? NSCursor.crosshair : overAnnotation ? .openHand : .arrow).set()
        case .text:
            let overText = textAnnotation(at: p) != nil
            (overImage ? (overText ? NSCursor.pointingHand : .iBeam) : .arrow).set()
        case .crop:
            let edges = cropEdges(at: p)
            (edges.isEmpty ? (overImage ? NSCursor.crosshair : .arrow) : edges.cursor).set()
        default:
            (overImage ? NSCursor.crosshair : .arrow).set()
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        document.showsOptions = false
        if textField != nil {
            endTextEditing()
            return
        }
        let p = imagePoint(event)
        let raw = imagePoint(event, clamped: false)
        let onImage = region.contains(raw)
        switch document.tool {
        case .select:
            if let selected = document.selected, let index = handleIndex(at: raw) {
                gesture = .handle(original: selected, index: index)
            } else if let hit = document.annotation(at: raw, tolerance: 4 / zoom) {
                if event.clickCount == 2, case .text = hit.kind {
                    beginTextEditing(editing: hit)
                    return
                }
                document.select(hit)
                gesture = .move(original: hit, start: p)
                NSCursor.closedHand.set()
            } else {
                document.select(nil)
            }
        case .text:
            if let hit = textAnnotation(at: raw) {
                beginTextEditing(editing: hit)
            } else if onImage {
                beginTextEditing(at: p)
            }
        case .step:
            guard onImage else { return }
            document.add(Annotation(kind: .step(center: p, number: document.nextStepNumber), color: document.color, size: document.size))
        case .crop:
            let edges = cropEdges(at: raw)
            gesture = edges.isEmpty ? .crop(origin: p) : .cropResize(original: document.visibleCrop, edges: edges, start: raw)
        default:
            gesture = .draw(origin: p)
            draft = makeDraft(from: p, to: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let gesture else { return }
        let p = imagePoint(event)
        switch gesture {
        case .draw(let origin):
            draft = makeDraft(from: origin, to: p)
            needsDisplay = true
        case .crop(let origin):
            cropDraft = CGRect(corners: origin, p)
            needsDisplay = true
        case .cropResize(let original, let edges, let start):
            let raw = imagePoint(event, clamped: false)
            cropDraft = edges.resizing(original, by: CGVector(dx: raw.x - start.x, dy: raw.y - start.y), within: document.imageBounds)
            needsDisplay = true
        case .move(let original, let start):
            // Uses the clamped point, so the grabbed spot always stays on the image.
            startLiveEditIfNeeded()
            document.replaceLive(original.offsetBy(dx: p.x - start.x, dy: p.y - start.y))
        case .handle(let original, let index):
            startLiveEditIfNeeded()
            document.replaceLive(original.movingHandle(index, to: p))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            gesture = nil
            liveEditStarted = false
            draft = nil
            cropDraft = nil
            needsDisplay = true
            updateCursor(at: event.locationInWindow)
        }
        switch gesture {
        case .crop:
            // A freshly drawn crop applies and returns to the previous tool.
            if let cropDraft, cropDraft.width >= 4, cropDraft.height >= 4 {
                document.pendingCrop = cropDraft
                document.finishCrop()
            }
        case .cropResize:
            // Edge drags stay pending in crop mode so several sides can be adjusted, then applied together.
            if let cropDraft, cropDraft.width >= 4, cropDraft.height >= 4 {
                document.pendingCrop = cropDraft
            }
        case .draw:
            if let draft, draft.isMeaningful { document.add(draft) }
        default:
            break
        }
    }

    private func startLiveEditIfNeeded() {
        guard !liveEditStarted else { return }
        liveEditStarted = true
        document.beginLiveEdit()
    }

    /// Crop edges under `p` (image points); 6pt grab distance on screen.
    private func cropEdges(at p: CGPoint) -> CropEdges {
        CropEdges.hit(p, rect: document.visibleCrop, tolerance: 6 / zoom)
    }

    private func textAnnotation(at p: CGPoint) -> Annotation? {
        guard let hit = document.annotation(at: p, tolerance: 2 / zoom), case .text = hit.kind else { return nil }
        return hit
    }

    private func handleIndex(at p: CGPoint) -> Int? {
        guard let selected = document.selected else { return nil }
        return selected.handles.firstIndex { hypot($0.x - p.x, $0.y - p.y) <= 7 / zoom }
    }

    /// Builds the in-progress annotation for the current tool.
    private func makeDraft(from origin: CGPoint, to p: CGPoint) -> Annotation? {
        let kind: Annotation.Kind
        switch (document.tool, draft?.kind) {
        case (.arrow, _): kind = .arrow(from: origin, to: p)
        case (.rect, _): kind = .rect(CGRect(corners: origin, p))
        case (.pixelate, _): kind = .pixelate(CGRect(corners: origin, p))
        case (.pen, .pen(let pts)?): kind = .pen(pts + [p])
        case (.pen, _): kind = .pen([p])
        case (.highlighter, .highlighter(let pts)?): kind = .highlighter(pts + [p])
        case (.highlighter, _): kind = .highlighter([p])
        default: return nil
        }
        return Annotation(kind: kind, color: document.color, size: document.size)
    }

    // MARK: Text

    /// Re-opens an existing text annotation for editing, in its own style.
    private func beginTextEditing(editing annotation: Annotation) {
        guard case .text(let origin, let string) = annotation.kind else { return }
        document.select(nil)
        document.adoptStyle(of: annotation)
        editingTextID = annotation.id
        beginTextEditing(at: origin, text: string)
        needsDisplay = true
    }

    private func beginTextEditing(at p: CGPoint, text: String = "") {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        let viewPoint = p.applying(transform)
        field.frame.origin = CGPoint(x: viewPoint.x - 2, y: viewPoint.y)
        textOrigin = p
        textField = field
        addSubview(field)
        styleTextField()
        window?.makeFirstResponder(field)
    }

    /// Keeps the open text field in the current color and size.
    private func styleTextField() {
        guard let field = textField else { return }
        field.font = NSFont.systemFont(ofSize: Annotation.font(for: document.size).pointSize * zoom, weight: .bold)
        field.textColor = document.color
        fitTextField()
    }

    func controlTextDidChange(_ notification: Notification) {
        fitTextField()
    }

    /// Sizes the field to the text being typed plus room for the next characters, so it never
    /// scrolls and hides what's already written. `sizeToFit` can't be used: it measures the
    /// committed value, not the live field-editor text.
    private func fitTextField() {
        guard let field = textField, let font = field.font else { return }
        let text = field.currentEditor()?.string ?? field.stringValue
        let measured = NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font]).size()
        field.setFrameSize(CGSize(width: ceil(measured.width) + font.pointSize * 1.5,
                                  height: ceil(font.ascender - font.descender + font.leading) + 4))
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        endTextEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            endTextEditing(commit: false)
            return true
        }
        return false
    }

    /// Commits (or discards) the text currently being typed, if any. Re-edited text that ends
    /// up empty is deleted.
    func endTextEditing(commit: Bool = true) {
        guard let field = textField else { return }
        textField = nil
        let editedID = editingTextID
        editingTextID = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
        guard commit else { return }

        let (color, size) = (document.color, document.size)
        if let editedID {
            if text.isEmpty { return document.remove(editedID) }
            guard let existing = document.state.annotations.first(where: { $0.id == editedID }),
                  case .text(_, let oldText) = existing.kind,
                  oldText != text || existing.color != color || existing.size != size else { return }
            document.update(editedID) {
                $0.kind = .text(origin: textOrigin, string: text)
                $0.color = color
                $0.size = size
            }
        } else if !text.isEmpty {
            document.add(Annotation(kind: .text(origin: textOrigin, string: text), color: color, size: size))
        }
    }

    // MARK: Keyboard

    /// Cancels an in-progress drag, restoring anything it changed live.
    private func abortGesture() {
        if liveEditStarted { document.cancelLiveEdit() }
        gesture = nil
        liveEditStarted = false
        draft = nil
        cropDraft = nil
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (mods, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "c"), ([.control], "c"): onCommand(.copy)
        case ([.command], "s"): onCommand(.save)
        case ([.command], "w"): onCommand(.close)
        case ([.command], "z"):
            if gesture != nil { abortGesture() }
            endTextEditing()
            if document.pendingCrop != nil { document.pendingCrop = nil } else { document.undo() }
        case ([.command, .shift], "z"):
            if gesture != nil { abortGesture() }
            endTextEditing()
            document.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc: abort a drag, close the popover, deselect, leave crop mode, then close the editor
            if gesture != nil { abortGesture() }
            else if document.isOptionsVisible { document.showsOptions = false }
            else if document.selectedID != nil { document.select(nil) }
            else if document.tool == .crop { document.cancelCrop() }
            else { onCommand(.close) }
            return
        case 36, 76: // Return / Enter: finish cropping, otherwise copy
            if document.tool == .crop { document.finishCrop() } else { onCommand(.copy) }
            return
        case 51, 117: // Delete / Forward Delete
            document.deleteSelected()
            return
        default:
            break
        }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, gesture == nil, let char = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = Tool.allCases.first(where: { $0.key == char }) {
            document.tool = tool
            return
        }
        super.keyDown(with: event)
    }
}
