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

    /// Turning it back off lives in the menu bar panel.
    func enableLaunchAtLogin() {
        LaunchAtLogin.set(true)
        refresh()
    }
}

// MARK: - Views

/// "Gallery wall" design: each step hangs as a framed picture (cream mat, terracotta frame, like
/// the app icon) on the ink wall.
private struct OnboardingView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                Text("Hang Framed on your wall").font(.system(size: 21, weight: .semibold, design: .serif)).foregroundStyle(Color.cream)
                Text("Two quick permissions and it's ready.").font(.system(size: 12.5)).foregroundStyle(Color.cream.opacity(0.6))
            }

            VStack(spacing: 18) {
                StepFrame(symbol: "rectangle.dashed.badge.record", title: "Allow Screen Recording",
                          detail: "So Framed can see what you capture.", isDone: model.hasPermission) {
                    Button(model.askedForPermission ? "Open Settings" : "Allow", action: model.allowScreenRecording)
                        .buttonStyle(StepButtonStyle())
                } footer: {
                    // macOS may only apply the grant after a relaunch.
                    if model.askedForPermission {
                        Button("Allowed it? Reopen Framed", action: model.relaunch).buttonStyle(LinkStyle())
                    }
                }
                StepFrame(symbol: "command", title: "Use ⇧⌘3 and ⇧⌘4",
                          detail: "Turns off the macOS screenshot shortcuts so the keys open Framed.", isDone: model.shortcutsFree) {
                    Button("Turn Off", action: model.turnOffSystemShortcuts).buttonStyle(StepButtonStyle())
                }
                StepFrame(symbol: "power", title: "Launch at Login", detail: "Stay in the menu bar after a restart.",
                          isDone: model.launchesAtLogin, isOptional: true, doneLabel: "On") {
                    Button("Turn On", action: model.enableLaunchAtLogin).buttonStyle(StepButtonStyle())
                }
            }

            HStack {
                Text(model.isComplete ? "You're all set. Press ⇧⌘4 to capture." : "\(requiredDone) of 2 required done")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.cream.opacity(0.6))
                Spacer(minLength: 12)
                Button("Start Using Framed", action: model.finish)
                    .buttonStyle(StepButtonStyle(large: true))
                    .disabled(!model.isComplete)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 20) // below the transparent title bar
        .padding(.bottom, 26)
        .frame(width: 500)
        .background {
            ZStack {
                RadialGradient(colors: [.ink, .inkDeep], center: .top, startRadius: 0, endRadius: 560)
                DotGrid(spacing: 14)
            }
            .ignoresSafeArea()
        }
        .animation(.snappy(duration: 0.2), value: model.hasPermission)
        .animation(.snappy(duration: 0.2), value: model.shortcutsFree)
        .animation(.snappy(duration: 0.2), value: model.launchesAtLogin)
        .animation(.snappy(duration: 0.2), value: model.askedForPermission)
        .environment(\.colorScheme, .dark)
    }

    private var requiredDone: Int { [model.hasPermission, model.shortcutsFree].filter { $0 }.count }
}

/// One step as a framed picture: icon, title and explanation on the mat, and its action on the
/// right, replaced by a "Done" seal once the system reports the step complete.
private struct StepFrame<Action: View, Footer: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let isDone: Bool
    var isOptional = false
    var doneLabel = "Done"
    @ViewBuilder var action: Action
    @ViewBuilder var footer: Footer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(Color.terracottaDeep).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.ink)
                    if isOptional {
                        Text("OPTIONAL").font(.system(size: 9, weight: .semibold)).kerning(0.5)
                            .foregroundStyle(Color.ink.opacity(0.55))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.ink.opacity(0.08), in: Capsule())
                    }
                }
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Color.ink.opacity(0.6)).fixedSize(horizontal: false, vertical: true)
                if !isDone { footer.padding(.top, 2) }
            }
            Spacer(minLength: 8)
            if isDone {
                Label(doneLabel, systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.terracottaDeep)
                    .transition(.scale.combined(with: .opacity))
            } else {
                action
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 62)
        .opacity(isDone ? 0.75 : 1)
        .framedPanel(cornerRadius: 6, frameWidth: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isDone ? "\(title), done" : title)
    }
}

extension StepFrame where Footer == EmptyView {
    init(symbol: String, title: String, detail: String, isDone: Bool, isOptional: Bool = false, doneLabel: String = "Done",
         @ViewBuilder action: () -> Action) {
        self.init(symbol: symbol, title: title, detail: detail, isDone: isDone, isOptional: isOptional, doneLabel: doneLabel,
                  action: action, footer: { EmptyView() })
    }
}

/// Terracotta button with a darker lip, like the menu bar's Capture button.
private struct StepButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: large ? 10 : 8, style: .continuous)
        configuration.label
            .font(.system(size: large ? 13.5 : 12, weight: .semibold))
            .foregroundStyle(Color.cream)
            .padding(.horizontal, large ? 18 : 12)
            .frame(height: large ? 34 : 28)
            .background(Color.terracotta, in: shape)
            .background(shape.fill(Color.terracottaDeep).offset(y: 2))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(shape)
    }
}

private struct LinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.terracottaDeep.opacity(configuration.isPressed ? 0.6 : 1))
            .contentShape(Rectangle())
    }
}
