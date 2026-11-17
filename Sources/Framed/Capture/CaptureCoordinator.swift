import AppKit

/// The ways to take a capture, as offered by the menu bar's Capture button.
enum CaptureMode: String, CaseIterable, Identifiable {
    case area, window, screen

    var id: Self { self }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .screen: "display"
        }
    }
    var shortcut: String {
        switch self {
        case .area: "⇧⌘4"
        case .window: "Space"
        case .screen: "⇧⌘3"
        }
    }
}

/// Runs the capture flow: freeze displays → overlay selection → open the annotation editor.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var overlays: [OverlayWindow] = []
    private var editors: [EditorWindowController] = []
    /// True from the trigger until the editor opens (or the capture is cancelled), so a second
    /// hotkey press during the async freeze can't start a parallel capture.
    private var isCapturing = false

    /// Delay for captures started from the menu bar menu, so its fade-out isn't captured.
    static let menuDismissDelay: Duration = .milliseconds(250)

    /// How the last completed capture was taken, from the menu or a hotkey (Space toggles count).
    /// Persisted so the menu bar's Capture button offers it again after relaunch.
    private(set) var lastMode: CaptureMode {
        get { UserDefaults.standard.string(forKey: "lastCaptureMode").flatMap(CaptureMode.init) ?? .area }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "lastCaptureMode") }
    }

    func capture(_ mode: CaptureMode, after delay: Duration = .zero) {
        switch mode {
        case .area: captureInteractive(after: delay)
        case .window: captureInteractive(after: delay, windowMode: true)
        case .screen: captureFullscreen(after: delay)
        }
    }

    /// `windowMode` starts the overlay picking whole windows (Space still toggles it).
    func captureInteractive(after delay: Duration = .zero, windowMode: Bool = false) {
        guard !isCapturing, ensurePermission() else { return }
        isCapturing = true
        Task {
            do {
                try await Task.sleep(for: delay)
                let windows = ScreenCapturer.windowsFrontToBack()
                let displays = try await ScreenCapturer.freezeDisplays()
                showOverlays(displays: displays, windows: windows, windowMode: windowMode)
            } catch {
                isCapturing = false
                presentError(error)
            }
        }
    }

    func captureFullscreen(after delay: Duration = .zero) {
        guard !isCapturing, ensurePermission() else { return }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            do {
                try await Task.sleep(for: delay)
                let displays = try await ScreenCapturer.freezeDisplays()
                let mouse = NSEvent.mouseLocation
                guard let display = displays.first(where: { $0.screen.frame.contains(mouse) }) ?? displays.first else { return }
                lastMode = .screen
                openEditor(image: display.image, scale: display.scale)
            } catch {
                presentError(error)
            }
        }
    }

    // MARK: Overlay

    private func showOverlays(displays: [FrozenDisplay], windows: [WindowTarget], windowMode: Bool) {
        for display in displays {
            let screenFrame = display.screen.frame
            let localWindows = windows.compactMap { window -> WindowTarget? in
                var local = window
                local.frame = window.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
                return local.frame.intersects(CGRect(origin: .zero, size: screenFrame.size)) ? local : nil
            }
            let view = OverlayView(frame: CGRect(origin: .zero, size: screenFrame.size), frozen: display.image, windows: localWindows)
            view.onFinish = { [weak self] outcome in self?.finish(outcome, display: display) }
            view.onToggleWindowMode = { [weak self] in self?.toggleWindowMode() }
            view.windowMode = windowMode
            overlays.append(OverlayWindow(screen: display.screen, content: view))
        }

        let mouse = NSEvent.mouseLocation
        for overlay in overlays {
            overlay.orderFrontRegardless()
            overlay.makeFirstResponder(overlay.contentView)
            (overlay.contentView as? OverlayView)?.syncMouse()
        }
        (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKey()
        NSCursor.crosshair.set() // show the selection cursor right away, before the mouse moves
    }

    /// Space switches every display's overlay together, so the mode doesn't depend on the screen.
    private func toggleWindowMode() {
        let views = overlays.compactMap { $0.contentView as? OverlayView }
        let enabled = !(views.first?.windowMode ?? false)
        views.forEach { $0.windowMode = enabled }
    }

    private func finish(_ outcome: OverlayView.Outcome?, display: FrozenDisplay) {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        guard let outcome else {
            isCapturing = false
            return
        }

        switch outcome {
        case .area(let rect):
            lastMode = .area
            openCropped(display: display, rect: rect)
            isCapturing = false
        case .window(let window):
            lastMode = .window
            Task {
                defer { isCapturing = false }
                do {
                    let capture = try await ScreenCapturer.captureWindow(window.id)
                    openEditor(image: capture.image, scale: capture.scale)
                } catch {
                    // Fall back to the visible part of the window from the frozen frame.
                    openCropped(display: display, rect: window.frame)
                }
            }
        }
    }

    private func openCropped(display: FrozenDisplay, rect: CGRect) {
        let imageSize = CGSize(width: display.image.width, height: display.image.height)
        let pixels = Geometry.pixelRect(forViewRect: rect, viewSize: display.screen.frame.size, imageSize: imageSize)
        guard let cropped = display.image.cropping(to: pixels) else { return }
        openEditor(image: cropped, scale: display.scale)
    }

    // MARK: Editor

    private func openEditor(image: CGImage, scale: CGFloat) {
        // While editors are open Framed shows in the Dock and ⌘Tab, so a window that slips
        // behind another app can always be brought back.
        NSApp.setActivationPolicy(.regular)
        let controller = EditorWindowController(document: EditorDocument(image: image, scale: scale), cascadeIndex: editors.count)
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            editors.removeAll { $0 === controller }
            guard editors.isEmpty else { return }
            NSApp.setActivationPolicy(.accessory)
            // Hand focus back to the app the user came from, so pasting works right away.
            if !isCapturing { NSApp.hide(nil) }
        }
        editors.append(controller)
        controller.present()
    }

    /// Reopens a saved capture (menu bar "Recent") in a new editor.
    func openFile(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return presentError(CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]))
        }
        // Exporter tags PNGs with their DPI (144 for Retina), which gives back the original scale.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = properties?[kCGImagePropertyDPIWidth] as? CGFloat ?? 72
        openEditor(image: image, scale: max(1, (dpi / 72).rounded()))
    }

    /// Brings open editors to the front (Dock icon click).
    func showEditors() {
        NSApp.activate()
        editors.forEach { $0.window?.makeKeyAndOrderFront(nil) }
    }

    /// Number of open editors holding annotations that would be lost.
    var unsavedEditorCount: Int { editors.count { $0.editorDocument.canUndo } }

    // MARK: Permission & errors

    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        requestPermission()
        return false
    }

    /// Asks for Screen Recording access, pointing to System Settings once the system prompt was used up.
    func requestPermission() {
        if CGRequestScreenCaptureAccess() { return }
        let alert = NSAlert()
        alert.messageText = "Framed needs Screen Recording access"
        alert.informativeText = "Enable Framed in System Settings → Privacy & Security → Screen & System Audio Recording. If macOS asks, let it quit and reopen Framed, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        NSApp.activate()
        alert.runModal()
    }
}
