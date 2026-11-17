import SwiftUI

/// Menu bar–only app (LSUIElement). Captures are triggered from the menu bar item or global hotkeys.
@main
struct FramedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// The menu bar item is AppKit (`MenuBarController`); this empty scene only satisfies `App`.
    var body: some Scene {
        Settings { EmptyView() }
            .commands { CommandGroup(replacing: .appSettings) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            MenuBarController.shared.install()
            HotKeys.registerDefaults()
            BackgroundCursor.enable()
            if OnboardingWindow.isNeeded { OnboardingWindow.shared.show() }
        }
    }

    /// Clicking the Dock icon (shown while editors or onboarding are open) brings them back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            CaptureCoordinator.shared.showEditors()
            if OnboardingWindow.shared.isVisible { OnboardingWindow.shared.show() }
        }
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
