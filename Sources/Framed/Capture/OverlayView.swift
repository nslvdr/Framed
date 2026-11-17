import AppKit

/// Transparent full-screen panel hosting the selection overlay for one display.
/// The live screen stays visible underneath; only selection UI is drawn on top. It is a
/// non-activating panel, so it takes keyboard input without deactivating the app being captured.
final class OverlayWindow: NSPanel {
    init(screen: NSScreen, content: NSView) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        ignoresMouseEvents = false // capture clicks even over fully transparent pixels
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        acceptsMouseMovedEvents = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = content
    }

    override var canBecomeKey: Bool { true }

    /// AppKit would otherwise push the window below the menu bar, misaligning the overlay.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Selection UI over the live screen; `frozen` (taken at hotkey time) is what gets captured and
/// feeds the loupe. Nothing is drawn until the user drags. Drag selects an area; Space toggles
/// window mode (click a highlighted window); Esc cancels. Coordinates are view-local (y up).
final class OverlayView: NSView {
    enum Outcome {
        case area(CGRect)
        case window(WindowTarget)
    }

    private let frozen: CGImage
    private let windows: [WindowTarget]
    var onFinish: (Outcome?) -> Void = { _ in }
    /// Space was pressed; the coordinator flips `windowMode` on every display's overlay.
    var onToggleWindowMode: () -> Void = {}

    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hovered: WindowTarget?
    private var mouse: CGPoint?

    var windowMode = false {
        didSet {
            selection = nil
            if window?.isKeyWindow == true || mouse != nil { currentCursor.set() }
            syncMouse()
        }
    }

    init(frame: CGRect, frozen: CGImage, windows: [WindowTarget]) {
        self.frozen = frozen
        self.windows = windows
        super.init(frame: frame)
    }

    /// Picks up the current mouse position without waiting for a move event, so the loupe and
    /// window highlight are right immediately.
    func syncMouse() {
        guard let window else { return }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        mouse = bounds.contains(p) ? p : nil
        hovered = windowMode ? mouse.flatMap { m in windows.first { $0.frame.contains(m) } } : nil
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { currentCursor.set() }

    private var currentCursor: NSCursor { windowMode ? .pointingHand : .crosshair }

    override func mouseMoved(with event: NSEvent) {
        currentCursor.set()
        let p = point(event)
        mouse = p
        hovered = windowMode ? windows.first { $0.frame.contains(p) } : nil
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        hovered = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = windowMode ? nil : point(event)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard !windowMode, let start = dragStart else { return }
        currentCursor.set()
        let p = point(event)
        mouse = p
        let rect = CGRect(corners: start, p)
        if rect.width >= 3 || rect.height >= 3 { selection = rect }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if windowMode {
            if let hovered { onFinish(.window(hovered)) }
        } else if let selection, selection.width >= 3, selection.height >= 3 {
            onFinish(.area(selection))
        } else {
            self.selection = nil // a click or tiny drag: keep waiting for a real selection
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onFinish(nil) // Esc
        case 49 where dragStart == nil: // Space toggles window mode, like the system tool
            onToggleWindowMode()
        default: break
        }
    }

    /// Mouse location clamped to the view so drags can't leave the display.
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if let selection {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.1).cgColor)
            ctx.fill(selection)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(selection.insetBy(dx: -0.5, dy: -0.5))
            drawSizeBadge(for: selection)
            if let mouse { drawLoupe(at: mouse, in: ctx) }
        } else if let highlight = hovered?.frame.intersection(bounds) {
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor)
            ctx.fill(highlight)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(highlight.insetBy(dx: 1.5, dy: 1.5))
        }
    }

    /// Shows the selection size in pixels, matching the size shown in the editor.
    private func drawSizeBadge(for rect: CGRect) {
        let pixels = Geometry.pixelRect(forViewRect: rect, viewSize: bounds.size, imageSize: CGSize(width: frozen.width, height: frozen.height))
        let text = NSAttributedString(string: "\(Int(pixels.width)) × \(Int(pixels.height))", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        var badge = CGRect(x: rect.maxX - size.width - 16, y: rect.minY - size.height - 14, width: size.width + 16, height: size.height + 6)
        if badge.minY < bounds.minY + 4 { badge.origin.y = rect.minY + 8 }
        badge.origin.x = max(badge.minX, bounds.minX + 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        text.draw(at: CGPoint(x: badge.minX + 8, y: badge.minY + 3))
    }

    /// Magnified, pixel-exact view of the area around the cursor for precise selection.
    /// Draws the whole frozen frame scaled around the cursor and clipped to the circle, so it
    /// never stretches near screen edges (off-screen parts are simply empty).
    private func drawLoupe(at p: CGPoint, in ctx: CGContext) {
        let size: CGFloat = 120, zoom: CGFloat = 8

        var origin = CGPoint(x: p.x + 24, y: p.y - 24 - size)
        if origin.x + size > bounds.maxX { origin.x = p.x - 24 - size }
        if origin.y < bounds.minY { origin.y = p.y + 24 }
        let loupe = CGRect(origin: origin, size: CGSize(width: size, height: size))

        ctx.saveGState()
        ctx.addEllipse(in: loupe)
        ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(loupe)
        ctx.interpolationQuality = .none
        ctx.draw(frozen, in: CGRect(x: loupe.midX - p.x * zoom, y: loupe.midY - p.y * zoom,
                                    width: bounds.width * zoom, height: bounds.height * zoom))
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: loupe.midX - zoom / 2, y: loupe.midY - zoom / 2, width: zoom, height: zoom))
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: loupe.insetBy(dx: 1, dy: 1))
    }
}
