import AppKit

enum EditorCommand {
    case copy, save, close
}

/// Interactive editing surface. Fits the visible region (the crop, or the whole image while
/// cropping) into the view, turns mouse input into annotations, and handles editor shortcuts.
final class CanvasView: NSView, NSTextFieldDelegate {
    let document: EditorDocument
    var onCommand: (EditorCommand) -> Void = { _ in }

    private var dragOrigin: CGPoint?
    private var draft: Annotation?
    private var cropDraft: CGRect?
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var lastDrawingTool: Tool = .arrow

    init(document: EditorDocument) {
        self.document = document
        super.init(frame: .zero)
        observeDocument()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Redraws whenever document state or the active tool changes.
    private func observeDocument() {
        withObservationTracking {
            _ = document.state
            _ = document.tool
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.document.tool != .crop { self.lastDrawingTool = self.document.tool }
                self.endTextEditing()
                self.needsDisplay = true
                self.window?.invalidateCursorRects(for: self)
                self.observeDocument()
            }
        }
    }

    // MARK: Coordinate mapping

    private var region: CGRect { document.tool == .crop ? document.imageBounds : document.state.crop }

    /// Image points → view points. Scales the region (up or down) to fill the view, keeping its aspect ratio.
    private var transform: CGAffineTransform {
        let region = region
        let available = bounds.insetBy(dx: 20, dy: 20)
        guard region.width > 0, region.height > 0, available.width > 0, available.height > 0 else { return .identity }
        let zoom = min(available.width / region.width, available.height / region.height)
        let origin = CGPoint(x: (bounds.midX - region.width * zoom / 2).rounded(), y: (bounds.midY - region.height * zoom / 2).rounded())
        return CGAffineTransform(translationX: origin.x, y: origin.y)
            .scaledBy(x: zoom, y: zoom)
            .translatedBy(x: -region.minX, y: -region.minY)
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil).applying(transform.inverted())
        let r = region
        return CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let transform = transform
        let card = region.applying(transform)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 28, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(card)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.clip(to: card)
        ctx.concatenate(transform)
        ctx.interpolationQuality = .high
        document.drawContent(in: ctx, draft: draft)
        ctx.restoreGState()

        if document.tool == .crop {
            let crop = (cropDraft ?? document.state.crop).applying(transform)
            let dim = CGMutablePath()
            dim.addRect(card)
            dim.addRect(crop)
            ctx.addPath(dim)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(.white)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.stroke(crop.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        endTextEditing()
    }

    // MARK: Mouse

    override func resetCursorRects() {
        addCursorRect(region.applying(transform), cursor: document.tool == .text ? .iBeam : .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        if textField != nil {
            endTextEditing()
            return
        }
        let p = imagePoint(event)
        switch document.tool {
        case .text:
            beginTextEditing(at: p)
        case .step:
            document.add(Annotation(kind: .step(center: p, number: document.nextStepNumber), color: document.color))
        case .crop:
            dragOrigin = p
            cropDraft = nil
        default:
            dragOrigin = p
            draft = makeDraft(to: p)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let p = imagePoint(event)
        if document.tool == .crop {
            cropDraft = CGRect(corners: origin, p)
        } else {
            draft = makeDraft(to: p)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            draft = nil
            cropDraft = nil
            needsDisplay = true
        }
        if document.tool == .crop {
            if let cropDraft, cropDraft.width >= 4, cropDraft.height >= 4 {
                document.setCrop(cropDraft)
                document.tool = lastDrawingTool
            }
        } else if let draft, draft.isMeaningful {
            document.add(draft)
        }
    }

    /// Builds the in-progress annotation from the drag origin to `p`.
    private func makeDraft(to p: CGPoint) -> Annotation? {
        guard let origin = dragOrigin else { return nil }
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
        return Annotation(kind: kind, color: document.color)
    }

    // MARK: Text

    private func beginTextEditing(at p: CGPoint) {
        let zoom = transform.a
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: Annotation.textFont.pointSize * zoom, weight: .bold)
        field.textColor = document.color
        field.delegate = self
        let viewPoint = p.applying(transform)
        field.frame = CGRect(x: viewPoint.x - 2, y: viewPoint.y, width: 40, height: 0)
        field.sizeToFit()
        field.frame.size.width = max(field.frame.width, 40)
        textOrigin = p
        textField = field
        addSubview(field)
        window?.makeFirstResponder(field)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = textField else { return }
        let width = field.frame.width
        field.sizeToFit()
        field.frame.size.width = max(field.frame.width + 8, 40, width)
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

    /// Commits (or discards) the text currently being typed, if any.
    func endTextEditing(commit: Bool = true) {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        if commit, !text.isEmpty {
            document.add(Annotation(kind: .text(origin: textOrigin, string: text), color: document.color))
        }
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (mods, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "c"), ([.control], "c"): onCommand(.copy)
        case ([.command], "s"): onCommand(.save)
        case ([.command], "w"): onCommand(.close)
        case ([.command], "z"): endTextEditing(); document.undo()
        case ([.command, .shift], "z"): endTextEditing(); document.redo()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc: leave crop mode first, otherwise close
            if document.tool == .crop { document.tool = lastDrawingTool } else { onCommand(.close) }
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
            onCommand(.copy)
            return
        }
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, let char = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = Tool.allCases.first(where: { $0.key == char }) {
            document.tool = tool
            return
        }
        super.keyDown(with: event)
    }
}
