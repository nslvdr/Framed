import SwiftUI

/// Menu bar–only app (LSUIElement). Captures are triggered from the menu or global hotkeys.
@main
struct FramedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Framed", systemImage: "viewfinder") {
            Button("Capture Area") { CaptureCoordinator.shared.captureInteractive(after: CaptureCoordinator.menuDismissDelay) }
                .keyboardShortcut("4", modifiers: [.command, .shift])
            Button("Capture Fullscreen") { CaptureCoordinator.shared.captureFullscreen(after: CaptureCoordinator.menuDismissDelay) }
                .keyboardShortcut("3", modifiers: [.command, .shift])
            Divider()
            Button("Open Captures Folder") { Exporter.revealCapturesFolder() }
            Button("Use ⇧⌘3 / ⇧⌘4 for Framed…") { SystemShortcuts.offerTakeover() }
            Divider()
            Button("Quit Framed") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            HotKeys.registerDefaults()
            BackgroundCursor.enable()
            // One dialog per launch: the system permission prompt first, the shortcut offer later.
            if CGPreflightScreenCaptureAccess() {
                SystemShortcuts.offerTakeoverOnce()
            } else {
                CGRequestScreenCaptureAccess()
            }
        }
    }

    /// Clicking the Dock icon (shown while editors are open) brings them back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { CaptureCoordinator.shared.showEditors() }
        return false
    }

    /// Asks before quitting would throw away annotated screenshots.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let count = CaptureCoordinator.shared.unsavedEditorCount
            guard count > 0 else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = count == 1 ? "Quit and discard the open screenshot?" : "Quit and discard \(count) open screenshots?"
            alert.informativeText = "Annotations that weren't copied or saved will be lost."
            alert.addButton(withTitle: "Quit").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel")
            NSApp.activate()
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }
}
