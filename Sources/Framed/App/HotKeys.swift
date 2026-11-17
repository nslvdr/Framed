import Carbon.HIToolbox

/// Global hotkeys via Carbon's RegisterEventHotKey (needs no Accessibility permission).
@MainActor
enum HotKeys {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef] = []
    private static var handlerInstalled = false

    /// ⇧⌘4 area, ⇧⌘3 fullscreen. The matching macOS screenshot shortcuts must be turned off
    /// in System Settings, otherwise the system handles these keys first.
    static func registerDefaults() {
        let mods = cmdKey | shiftKey
        register(keyCode: kVK_ANSI_4, modifiers: mods) { CaptureCoordinator.shared.captureInteractive(after: dismissOnboarding()) }
        register(keyCode: kVK_ANSI_3, modifiers: mods) { CaptureCoordinator.shared.captureFullscreen(after: dismissOnboarding()) }
    }

    /// Closes a finished onboarding window, returning how long to wait so it's gone from the capture.
    private static func dismissOnboarding() -> Duration {
        OnboardingWindow.shared.dismissForCapture() ? CaptureCoordinator.menuDismissDelay : .zero
    }

    static func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4652_4D44), id: id) // 'FRMD'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if let ref { refs.append(ref) }
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            MainActor.assumeIsolated { HotKeys.actions[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
