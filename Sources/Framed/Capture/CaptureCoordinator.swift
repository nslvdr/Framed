import AppKit

/// Runs the capture flow: freeze displays → overlay selection → open the annotation editor.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var overlays: [OverlayWindow] = []
    private var editors: [EditorWindowController] = []

    func captureInteractive() {
        guard overlays.isEmpty, ensurePermission() else { return }
        Task {
            do {
                let windows = ScreenCapturer.windowsFrontToBack()
                let displays = try await ScreenCapturer.freezeDisplays()
                showOverlays(displays: displays, windows: windows)
            } catch {
                presentError(error)
            }
        }
    }

    func captureFullscreen() {
        guard overlays.isEmpty, ensurePermission() else { return }
        Task {
            do {
                let displays = try await ScreenCapturer.freezeDisplays()
                let mouse = NSEvent.mouseLocation
                guard let display = displays.first(where: { $0.screen.frame.contains(mouse) }) ?? displays.first else { return }
                openEditor(image: display.image, scale: display.scale)
            } catch {
                presentError(error)
            }
        }
    }

    // MARK: Overlay

    private func showOverlays(displays: [FrozenDisplay], windows: [WindowTarget]) {
        for display in displays {
            let screenFrame = display.screen.frame
            let localWindows = windows.compactMap { window -> WindowTarget? in
                var local = window
                local.frame = window.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
                return local.frame.intersects(CGRect(origin: .zero, size: screenFrame.size)) ? local : nil
            }
            let view = OverlayView(frame: CGRect(origin: .zero, size: screenFrame.size), frozen: display.image, windows: localWindows) { [weak self] outcome in
                self?.finish(outcome, display: display)
            }
            overlays.append(OverlayWindow(screen: display.screen, content: view))
        }

        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        for overlay in overlays {
            overlay.orderFrontRegardless()
            overlay.makeFirstResponder(overlay.contentView)
        }
        (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKey()
        NSCursor.crosshair.set() // show the selection cursor right away, before the mouse moves
    }

    private func finish(_ outcome: OverlayView.Outcome?, display: FrozenDisplay) {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        guard let outcome else { return }

        switch outcome {
        case .area(let rect):
            openCropped(display: display, rect: rect)
        case .window(let window):
            Task {
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
        let controller = EditorWindowController(document: EditorDocument(image: image, scale: scale))
        controller.onClose = { [weak self, weak controller] in
            self?.editors.removeAll { $0 === controller }
        }
        editors.append(controller)
        controller.present()
    }

    // MARK: Permission & errors

    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if CGRequestScreenCaptureAccess() { return true }
        let alert = NSAlert()
        alert.messageText = "Framed needs Screen Recording access"
        alert.informativeText = "Enable Framed in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        NSApp.activate()
        alert.runModal()
    }
}
