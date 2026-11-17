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
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            SystemShortcuts.resolveConflictIfNeeded()
        }
    }
}
