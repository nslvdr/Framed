import SwiftUI

/// Window that hosts the annotation editor for one capture.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let editorDocument: EditorDocument
    var onClose: () -> Void = {}
    private let canvas: CanvasView

    init(document: EditorDocument) {
        self.editorDocument = document
        canvas = CanvasView(document: document)

        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar gives a 52pt titlebar with centered traffic lights for our own toolbar.
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = CGSize(width: 720, height: 420)
        window.title = "Framed"
        super.init(window: window)

        canvas.onCommand = { [weak self] in self?.perform($0) }
        window.contentView = NSHostingView(rootView: EditorView(document: document, canvas: canvas) { [weak self] in self?.perform($0) })
        window.delegate = self
        window.setFrame(Self.initialFrame(), display: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    func perform(_ command: EditorCommand) {
        canvas.endTextEditing()
        switch command {
        case .copy:
            guard let image = editorDocument.render() else { return }
            Exporter.copy(image, scale: editorDocument.scale)
        case .save:
            guard let image = editorDocument.render() else { return }
            do {
                try Exporter.save(image, scale: editorDocument.scale)
            } catch {
                NSAlert(error: error).beginSheetModal(for: window!)
                return
            }
        case .close:
            break
        }
        close()
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    /// 75% of the visible area of the screen under the cursor, centered on it.
    private static func initialFrame() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        return visible.insetBy(dx: visible.width * 0.125, dy: visible.height * 0.125).integral
    }
}

private struct EditorView: View {
    @Bindable var document: EditorDocument
    let canvas: CanvasView
    let perform: (EditorCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .frame(height: 52)
            CanvasHost(canvas: canvas)
                .background(Color.black.opacity(0.18))
        }
        .ignoresSafeArea()
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 64) // traffic lights

            HStack(spacing: 2) {
                ForEach(Tool.allCases) { tool in
                    Button { document.tool = tool } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(document.tool == tool ? Color.white : Color.primary)
                    .background(document.tool == tool ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
                    .help("\(tool.title) (\(String(tool.key).uppercased()))")
                }
            }
            .padding(3)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))

            HStack(spacing: 6) {
                ForEach(EditorDocument.palette, id: \.self) { color in
                    Button { document.color = color } label: {
                        Circle()
                            .fill(Color(nsColor: color))
                            .overlay(Circle().strokeBorder(.primary.opacity(0.2), lineWidth: 1))
                            .frame(width: 16, height: 16)
                            .padding(3)
                            .overlay(Circle().strokeBorder(document.color == color ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button { document.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!document.canUndo)
                    .help("Undo (⌘Z)")
                Button { document.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!document.canRedo)
                    .help("Redo (⇧⌘Z)")
            }
            .buttonStyle(.borderless)

            Button("Copy") { perform(.copy) }
                .help("Copy and close (⌘C)")
            Button("Save") { perform(.save) }
                .buttonStyle(.borderedProminent)
                .help("Save to Pictures/Framed and close (⌘S)")
        }
        .controlSize(.large)
        .padding(.horizontal, 12)
    }
}

private struct CanvasHost: NSViewRepresentable {
    let canvas: CanvasView
    func makeNSView(context: Context) -> CanvasView { canvas }
    func updateNSView(_ nsView: CanvasView, context: Context) {}
}
