import AppKit

/// The macOS screenshot shortcuts that collide with Framed's ⇧⌘3 / ⇧⌘4. While they're enabled,
/// the system handles the keys too, so both tools run.
enum SystemShortcuts {
    private static let domain = "com.apple.symbolichotkeys"
    private static let key = "AppleSymbolicHotKeys"

    /// Symbolic hotkey IDs → default (char, keyCode, modifiers): save/copy screen, save/copy area.
    private static let screenshotDefaults: [Int: [Int]] = [
        28: [51, 20, 1_179_648], // ⇧⌘3
        29: [51, 20, 1_441_792], // ⌃⇧⌘3
        30: [52, 21, 1_179_648], // ⇧⌘4
        31: [52, 21, 1_441_792], // ⌃⇧⌘4
    ]

    /// A shortcut missing from the plist uses the system default, which is enabled.
    static var conflictsWithFramed: Bool {
        let hotkeys = UserDefaults(suiteName: domain)?.dictionary(forKey: key) ?? [:]
        return screenshotDefaults.keys.contains { id in
            let entry = hotkeys[String(id)] as? [String: Any]
            return (entry?["enabled"] as? Bool) ?? true
        }
    }

    /// Disables the system screenshot shortcuts (re-enable them in System Settings → Keyboard).
    static func disable() {
        guard let defaults = UserDefaults(suiteName: domain) else { return }
        var hotkeys = defaults.dictionary(forKey: key) ?? [:]
        for (id, parameters) in screenshotDefaults {
            var entry = hotkeys[String(id)] as? [String: Any]
                ?? ["value": ["parameters": parameters, "type": "standard"]]
            entry["enabled"] = false
            hotkeys[String(id)] = entry
        }
        defaults.set(hotkeys, forKey: key)
        defaults.synchronize()

        // Makes the change take effect immediately instead of after the next login.
        let activate = Process()
        activate.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        activate.arguments = ["-u"]
        try? activate.run()
    }

    /// Offers to turn the conflicting shortcuts off; called at launch.
    @MainActor
    static func resolveConflictIfNeeded() {
        guard conflictsWithFramed else { return }
        let alert = NSAlert()
        alert.messageText = "Use Framed for ⇧⌘3 and ⇧⌘4?"
        alert.informativeText = "The macOS screenshot shortcuts are still on, so pressing them opens both the system tool and Framed. Framed can turn the system ones off. You can turn them back on any time in System Settings → Keyboard → Keyboard Shortcuts → Screenshots."
        alert.addButton(withTitle: "Turn Off macOS Shortcuts")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { disable() }
    }
}
