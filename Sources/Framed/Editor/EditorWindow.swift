import SwiftUI

/// Window that hosts the annotation editor for one capture ("Floating Dock" design).
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let editorDocument: EditorDocument
    var onClose: () -> Void = {}
    private let canvas: CanvasView

    /// `cascadeIndex` offsets the window so several open editors don't stack exactly.
    init(document: EditorDocument, cascadeIndex: Int = 0) {
        self.editorDocument = document
        canvas = CanvasView(document: document)

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar centers the traffic lights 26pt from the top, matching the 52pt title bar below.
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary] // open where the user is, even over fullscreen apps
        window.minSize = CGSize(width: 720, height: 460)
        window.title = "Framed"
        super.init(window: window)

        canvas.onCommand = { [weak self] in self?.perform($0) }
        window.contentView = NSHostingView(rootView: EditorView(document: document, canvas: canvas) { [weak self] in self?.perform($0) })
        window.delegate = self
        window.setFrame(Self.initialFrame(cascadeIndex: cascadeIndex), display: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    func perform(_ command: EditorCommand) {
        switch command {
        case .undo: return canvas.undo()
        case .redo: return canvas.redo()
        default: break
        }
        canvas.endTextEditing()
        editorDocument.finishCrop() // export what's on screen, including pending crop adjustments
        switch command {
        case .copy:
            guard let image = editorDocument.render() else { return }
            Exporter.copy(image, scale: editorDocument.scale)
            MenuBarController.shared.flashConfirmation()
        case .save:
            guard let image = editorDocument.render() else { return }
            do {
                try Exporter.save(image, scale: editorDocument.scale)
                MenuBarController.shared.flashConfirmation()
            } catch {
                NSAlert(error: error).beginSheetModal(for: window!)
                return
            }
        case .close:
            window?.performClose(nil) // goes through windowShouldClose's confirmation
            return
        case .undo, .redo:
            return
        }
        close()
    }

    /// Asks before throwing away annotations (Esc, ⌘W or the close button).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard editorDocument.canUndo, sender.attachedSheet == nil else { return sender.attachedSheet == nil }
        let alert = NSAlert()
        alert.messageText = "Discard this screenshot?"
        alert.informativeText = "Your annotations will be lost."
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    /// 75% of the visible area of the screen under the cursor, centered on it, nudged per cascade step.
    private static func initialFrame(cascadeIndex: Int) -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let step = CGFloat(cascadeIndex % 6) * 28
        return visible.insetBy(dx: visible.width * 0.125, dy: visible.height * 0.125).integral.offsetBy(dx: step, dy: -step)
    }
}

// MARK: - Editor chrome

private struct EditorView: View {
    @Bindable var document: EditorDocument
    let canvas: CanvasView
    let perform: (EditorCommand) -> Void

    var body: some View {
        CanvasHost(canvas: canvas)
            .background(CanvasBackground())
            .overlay(alignment: .top) { titleBar }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if document.isOptionsVisible {
                        OptionsPopover(document: document)
                            .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
                    }
                    Dock(document: document, perform: perform)
                }
                .padding(.bottom, 18)
                .animation(.snappy(duration: 0.2), value: document.isOptionsVisible)
            }
            .ignoresSafeArea()
            .environment(\.colorScheme, .dark)
    }

    private var titleBar: some View {
        ZStack {
            HStack(spacing: 6) {
                Text("Screenshot").foregroundStyle(.secondary)
                Text(pixelSize).foregroundStyle(.tertiary).monospacedDigit()
            }
            .font(.system(size: 12.5, weight: .medium))

            HStack(spacing: 8) {
                Spacer()
                Button { perform(.copy) } label: { Label("Copy", systemImage: "doc.on.doc").shortcutHint("⌘C") }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .help("Copy to clipboard and close (⌘C)")
                Button { perform(.save) } label: { Label("Save", systemImage: "arrow.down.to.line").shortcutHint("⌘S") }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .help("Save to Pictures/Framed and close (⌘S)")
            }
            .padding(.trailing, 14)
            .focusable(false)
        }
        .frame(height: 52)
    }

    private var pixelSize: String {
        let crop = document.visibleCrop
        return "\(Int((crop.width * document.scale).rounded())) × \(Int((crop.height * document.scale).rounded()))"
    }
}

/// Ink radial gradient (the icon's wall) with a subtle dot grid behind the image.
private struct CanvasBackground: View {
    var body: some View {
        ZStack {
            RadialGradient(colors: [.ink, .inkDeep], center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 900)
            DotGrid()
        }
    }
}

private struct Dock: View {
    @Bindable var document: EditorDocument
    let perform: (EditorCommand) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tool.allCases) { tool in
                DockButton(symbol: tool.symbol, isOn: document.tool == tool, help: "\(tool.title)  \(String(tool.key).uppercased())") {
                    if document.tool == tool {
                        document.showsOptions.toggle()
                    } else {
                        document.tool = tool
                        document.showsOptions = true
                    }
                }
            }

            DockSeparator()

            Button { document.showsOptions.toggle() } label: {
                Circle()
                    .fill(Color(nsColor: document.color))
                    .frame(width: 20, height: 20)
                    .padding(2.5)
                    .overlay(Circle().strokeBorder(Color.ink, lineWidth: 1.5))
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!document.hasStyleOptions)
            .opacity(document.hasStyleOptions ? 1 : 0.35)
            .help("Color & size")

            DockSeparator()

            DockButton(symbol: "arrow.uturn.backward", help: "Undo  ⌘Z") { perform(.undo) }
                .disabled(!document.canUndo)
            DockButton(symbol: "arrow.uturn.forward", help: "Redo  ⇧⌘Z") { perform(.redo) }
                .disabled(!document.canRedo)
        }
        .padding(6)
        .framedPanel(cornerRadius: 14)
        .focusable(false)
    }
}

/// Color and size choices for the active tool (or the selected annotation).
private struct OptionsPopover: View {
    @Bindable var document: EditorDocument

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 7) {
                ForEach(EditorDocument.palette, id: \.self) { color in
                    let isOn = document.color == color
                    Button { document.setColor(color) } label: {
                        Circle()
                            .fill(Color(nsColor: color))
                            .overlay(Circle().strokeBorder(Color.ink.opacity(0.2), lineWidth: 0.5))
                            .frame(width: 18, height: 18)
                            .padding(2.5)
                            .overlay(Circle().strokeBorder(Color.ink.opacity(isOn ? 1 : 0), lineWidth: 1.5))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Rectangle().fill(Color.ink.opacity(0.14)).frame(width: 1, height: 20)

            HStack(spacing: 4) {
                ForEach(StrokeSize.allCases) { size in
                    Button { document.setSize(size) } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.ink)
                            .frame(width: 14, height: [2, 4, 7][size.rawValue])
                            .frame(width: 30, height: 26)
                            .background {
                                if document.size == size {
                                    RoundedRectangle(cornerRadius: 7).fill(Color.sand)
                                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.clay))
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(size.title)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .framedPanel(cornerRadius: 12)
        .focusable(false)
    }
}

// MARK: - Components

private struct DockButton: View {
    let symbol: String
    var isOn = false
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    // A StateObject rather than @State: the Command Line Tools ship without SwiftUI's macro plugin.
    @StateObject private var hover = HoverState()
    private var isHovering: Bool { hover.isHovering }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(isOn ? Color.cream : Color.ink.opacity(isEnabled ? 1 : 0.3))
                .frame(width: 38, height: 38)
                .background {
                    let tile = RoundedRectangle(cornerRadius: 9, style: .continuous)
                    if isOn {
                        tile.fill(Color.terracotta)
                            .background(tile.fill(Color.terracottaDeep).offset(y: 2)) // raised, pressable edge
                    } else {
                        tile.fill(Color.ink.opacity(isHovering && isEnabled ? 0.07 : 0))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hover.isHovering = $0 }
        .help(help)
    }
}

private struct DockSeparator: View {
    var body: some View {
        Rectangle().fill(Color.ink.opacity(0.14)).frame(width: 1, height: 22).padding(.horizontal, 5)
    }
}

/// Title bar buttons: prominent is a framed terracotta button with a raised edge, the other a quiet cream outline.
/// Both are 30pt tall overall; the prominent raised edge sits inside that height rather than below it.
private struct PillButtonStyle: ButtonStyle {
    let prominent: Bool
    private let height: CGFloat = 30
    private let edge: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return configuration.label
            .font(.system(size: 13, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(prominent ? Color.white : Color.cream)
            .padding(.horizontal, 12)
            .frame(height: prominent ? height - edge : height)
            .background {
                if prominent {
                    shape.fill(Color.terracotta).overlay(shape.strokeBorder(Color.terracottaDeep))
                } else {
                    shape.fill(Color.cream.opacity(0.08))
                        .overlay(shape.strokeBorder(Color.cream.opacity(0.16)))
                }
            }
            .padding(.bottom, prominent ? edge : 0)
            .background { if prominent { shape.fill(Color.terracottaDeep) } }
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private extension Label where Title == Text, Icon == Image {
    /// Appends a dimmed keyboard shortcut after the title.
    func shortcutHint(_ hint: String) -> some View {
        HStack(spacing: 5) {
            self
            Text(hint).font(.system(size: 11, weight: .medium)).opacity(0.55)
        }
    }
}

private struct CanvasHost: NSViewRepresentable {
    let canvas: CanvasView
    func makeNSView(context: Context) -> CanvasView { canvas }
    func updateNSView(_ nsView: CanvasView, context: Context) {}
}
