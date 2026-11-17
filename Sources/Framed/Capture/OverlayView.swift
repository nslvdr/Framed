import AppKit

/// Transparent full-screen window hosting the selection overlay for one display.
/// The live screen stays visible underneath; only selection UI is drawn on top.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen, content: NSView) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        ignoresMouseEvents = false // capture clicks even over fully transparent pixels
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        acceptsMouseMovedEvents = true
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
    private let onFinish: (Outcome?) -> Void

    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hovered: WindowTarget?
    private var mouse: CGPoint?
    private var windowMode = false

    init(frame: CGRect, frozen: CGImage, windows: [WindowTarget], onFinish: @escaping (Outcome?) -> Void) {
        self.frozen = frozen
        self.windows = windows
        self.onFinish = onFinish
        super.init(frame: frame)
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
            windowMode.toggle()
            selection = nil
            currentCursor.set()
            if let mouse { hovered = windowMode ? windows.first { $0.frame.contains(mouse) } : nil }
            needsDisplay = true
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

    private func drawSizeBadge(for rect: CGRect) {
        let text = NSAttributedString(string: "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))", attributes: [
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
    private func drawLoupe(at p: CGPoint, in ctx: CGContext) {
        let size: CGFloat = 120, zoom: CGFloat = 8
        let sourcePoints = size / zoom
        let viewSource = CGRect(x: p.x - sourcePoints / 2, y: p.y - sourcePoints / 2, width: sourcePoints, height: sourcePoints)
        let imageSize = CGSize(width: frozen.width, height: frozen.height)
        let pixels = Geometry.pixelRect(forViewRect: viewSource, viewSize: bounds.size, imageSize: imageSize)
        guard let crop = frozen.cropping(to: pixels) else { return }

        var origin = CGPoint(x: p.x + 24, y: p.y - 24 - size)
        if origin.x + size > bounds.maxX { origin.x = p.x - 24 - size }
        if origin.y < bounds.minY { origin.y = p.y + 24 }
        let loupe = CGRect(origin: origin, size: CGSize(width: size, height: size))

        ctx.saveGState()
        ctx.addEllipse(in: loupe)
        ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: loupe)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: loupe.midX - zoom / 2, y: loupe.midY - zoom / 2, width: zoom, height: zoom))
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: loupe.insetBy(dx: 1, dy: 1))
    }
}
