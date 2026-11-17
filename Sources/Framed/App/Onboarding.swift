import AppKit
import Observation
import SwiftUI

/// The setup window: Screen Recording and the ⇧⌘3 / ⇧⌘4 takeover (both required) plus Launch at
/// Login (optional). Each step ticks itself off as soon as the system reports it done, and the
/// window can't be dismissed until both required steps are.
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()

    /// Whether a required step is missing, i.e. Framed can't capture as intended yet.
    static var isNeeded: Bool { !CGPreflightScreenCaptureAccess() || SystemShortcuts.conflictsWithFramed }

    private let model = OnboardingModel()
    private var window: NSWindow?
    private var timer: Timer?

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        model.refresh()
        model.finish = { [weak self] in self?.finish() }
        let window = window ?? makeWindow()
        self.window = window
        // In the Dock and ⌘Tab while open, so it can always be found again behind System Settings.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        // The steps are completed in System Settings, which doesn't notify us: poll while visible.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { OnboardingWindow.shared.poll() }
        }
    }

    private func poll() {
        let wasComplete = model.isComplete
        model.refresh()
        // Come back from System Settings to show the finished checklist.
        if model.isComplete, !wasComplete {
            NSApp.activate()
            window?.makeKeyAndOrderFront(nil)
        }
    }

    private func finish() {
        guard model.isComplete else { return }
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        if !CaptureCoordinator.shared.hasOpenEditors { NSApp.setActivationPolicy(.accessory) }
    }

    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }

    private func makeWindow() -> NSWindow {
        // No close button: the only way out is "Start Using Framed", once the required steps are done.
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.title = "Set Up Framed"
        window.delegate = self
        let host = NSHostingView(rootView: OnboardingView(model: model))
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.center()
        return window
    }
}

// MARK: - Model

@MainActor @Observable
final class OnboardingModel {
    var hasPermission = false
    var shortcutsFree = false
    var launchesAtLogin = false
    /// Set once the system prompt was triggered; later clicks go straight to System Settings.
    var askedForPermission = false
    @ObservationIgnored var finish: () -> Void = {}

    var isComplete: Bool { hasPermission && shortcutsFree }

    func refresh() {
        hasPermission = CGPreflightScreenCaptureAccess()
        shortcutsFree = !SystemShortcuts.conflictsWithFramed
        launchesAtLogin = LaunchAtLogin.isEnabled
    }

    /// The first click shows the system prompt (which also lists Framed in System Settings);
    /// later ones open the Screen Recording pane directly.
    func allowScreenRecording() {
        if askedForPermission {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        } else {
            askedForPermission = true
            CGRequestScreenCaptureAccess()
        }
        refresh()
    }

    /// macOS may only apply a new Screen Recording grant after a relaunch.
    func relaunch() {
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "sleep 1; open \"$0\"", Bundle.main.bundlePath]
        try? reopen.run()
        NSApp.terminate(nil)
    }

    func turnOffSystemShortcuts() {
        SystemShortcuts.disable()
        refresh()
    }

    func toggleLaunchAtLogin() {
        LaunchAtLogin.set(!launchesAtLogin)
        refresh()
    }
}

// MARK: - Views

private struct OnboardingView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Welcome to Framed").font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.cream)
                    Text("Three quick steps and you're ready to capture.").font(.system(size: 12.5)).foregroundStyle(Color.cream.opacity(0.6))
                }
            }
            .padding(.bottom, 20)

            VStack(spacing: 10) {
                StepRow(number: 1, title: "Allow Screen Recording",
                        detail: "Framed needs to see your screen to capture it. Turn Framed on under Privacy & Security → Screen & System Audio Recording.",
                        isDone: model.hasPermission) {
                    HStack(spacing: 12) {
                        Button(model.askedForPermission ? "Open System Settings" : "Allow Screen Recording", action: model.allowScreenRecording)
                            .buttonStyle(StepButtonStyle())
                        if model.askedForPermission {
                            Button("Allowed it? Reopen Framed", action: model.relaunch).buttonStyle(LinkStyle())
                        }
                    }
                }
                StepRow(number: 2, title: "Use ⇧⌘3 and ⇧⌘4 for Framed",
                        detail: "Turns off the macOS screenshot shortcuts so the keys open Framed instead of both tools. You can turn them back on in System Settings → Keyboard.",
                        isDone: model.shortcutsFree) {
                    Button("Turn Off macOS Shortcuts", action: model.turnOffSystemShortcuts).buttonStyle(StepButtonStyle())
                }
                StepRow(number: 3, title: "Launch at Login", detail: "Keeps Framed in the menu bar after you restart your Mac.",
                        isDone: model.launchesAtLogin, isOptional: true, showsActionWhenDone: true) {
                    Button(model.launchesAtLogin ? "Turn Off" : "Turn On", action: model.toggleLaunchAtLogin)
                        .buttonStyle(StepButtonStyle(prominent: !model.launchesAtLogin))
                }
            }

            HStack {
                Text(model.isComplete ? "You're all set. Press ⇧⌘4 to capture an area." : "Finish the two required steps to start.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.cream.opacity(0.6))
                Spacer(minLength: 12)
                Button("Start Using Framed", action: model.finish)
                    .buttonStyle(StepButtonStyle())
                    .disabled(!model.isComplete)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 36) // clears the transparent title bar
        .padding(.bottom, 22)
        .frame(width: 500)
        .background {
            ZStack {
                RadialGradient(colors: [.ink, .inkDeep], center: .top, startRadius: 0, endRadius: 520)
                DotGrid(spacing: 14)
            }
            .ignoresSafeArea()
        }
        .animation(.snappy(duration: 0.2), value: model.hasPermission)
        .animation(.snappy(duration: 0.2), value: model.shortcutsFree)
        .animation(.snappy(duration: 0.2), value: model.launchesAtLogin)
        .environment(\.colorScheme, .dark)
    }
}

/// One checklist step: a numbered badge that turns into a check, the explanation and its action.
/// Required steps drop their action once done; the check is all that's left.
private struct StepRow<Action: View>: View {
    let number: Int
    let title: String
    let detail: String
    let isDone: Bool
    var isOptional = false
    var showsActionWhenDone = false
    @ViewBuilder var action: Action

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isDone ? Color.terracotta : .clear)
                    .overlay(Circle().strokeBorder(isDone ? Color.terracottaDeep : Color.cream.opacity(0.3), lineWidth: 1.5))
                if isDone {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(number)").font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(Color.cream)
            .frame(width: 24, height: 24)
            .accessibilityLabel(isDone ? "Done" : "Step \(number)")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.cream)
                    if isOptional {
                        Text("OPTIONAL").font(.system(size: 9, weight: .semibold)).kerning(0.5)
                            .foregroundStyle(Color.cream.opacity(0.55))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.cream.opacity(0.08), in: Capsule())
                    }
                }
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.cream.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                if !isDone || showsActionWhenDone {
                    action.padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.cream.opacity(isDone ? 0.035 : 0.07), in: shape)
        .overlay(shape.strokeBorder(isDone ? Color.terracotta.opacity(0.45) : .white.opacity(0.08)))
    }
}

/// Terracotta button with the darker lip of the menu bar's Capture button; `prominent: false` is a quiet cream variant.
private struct StepButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.cream)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(prominent ? Color.terracotta : Color.cream.opacity(0.12), in: shape)
            .background(shape.fill(prominent ? Color.terracottaDeep : .black.opacity(0.3)).offset(y: 2))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(shape)
    }
}

private struct LinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color.sun.opacity(configuration.isPressed ? 0.6 : 1))
            .contentShape(Rectangle())
    }
}
