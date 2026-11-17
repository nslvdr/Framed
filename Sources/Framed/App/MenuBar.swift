import AppKit
import Observation
import ServiceManagement
import SwiftUI

/// The menu bar icon and the panel it opens: Framed's own "menu", drawn in the editor's style
/// (ink wall, a terracotta Capture split button in the header, recent captures as framed rows).
@MainActor
final class MenuBarController: NSObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private let model = MenuModel()
    private lazy var panel = MenuPanel(content: MenuPanelView(model: model))
    private var clickMonitor: Any?
    /// When the panel last closed. Clicking the icon while the panel is open closes it on mouse-down
    /// (it loses key focus) just before the icon's action runs, which must not reopen it.
    private var closedAt = Date.distantPast
    private var flashTask: Task<Void, Never>?

    private static let icon = hangingFrameIcon()

    /// Call once at launch.
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "FramedStatusItem" // keeps the position the user ⌘-drags it to
        item.button?.image = Self.icon
        item.button?.toolTip = "Framed"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown]) // opens on press, like a menu
        statusItem = item
        model.close = { [weak self] in self?.closePanel() }
    }

    /// Briefly swaps the icon for a checkmark, confirming a copy or save after the editor closes.
    func flashConfirmation() {
        guard let button = statusItem?.button else { return }
        flashTask?.cancel()
        button.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Done")
        flashTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            button.image = Self.icon
        }
    }

    // MARK: Panel

    @objc private func togglePanel() {
        if panel.isVisible {
            closePanel()
        } else if Date.now.timeIntervalSince(closedAt) > 0.25 {
            openPanel()
        }
    }

    private func openPanel() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        model.refresh()
        if let host = panel.contentView { panel.setContentSize(host.fittingSize) }

        // Below the icon, left-aligned with it like a menu, kept on screen.
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        let visible = buttonWindow.screen?.visibleFrame ?? anchor
        let x = min(max(anchor.minX - 8, visible.minX + 6), visible.maxX - size.width - 6)
        panel.setFrameTopLeftPoint(CGPoint(x: x, y: anchor.minY - 5))
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        DispatchQueue.main.async { self.panel.invalidateShadow() } // shadow follows the rounded content once drawn

        // Any click in another app closes the panel, as with a menu.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { _ in
            MainActor.assumeIsolated { MenuBarController.shared.closePanel() }
        }
    }

    func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        closedAt = .now
        statusItem?.button?.highlight(false)
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    // MARK: Icon

    /// Monochrome template glyph of the app icon: a tilted picture frame hanging from a nail.
    /// Drawn in a 24-unit, y-down grid; both cords end on the frame's tilted top edge.
    private static func hangingFrameIcon() -> NSImage {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.scaleBy(x: 18 / 24, y: 18 / 24)
            ctx.setFillColor(.black)
            ctx.setStrokeColor(.black)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            ctx.setLineWidth(1.6)
            ctx.addLines(between: [CGPoint(x: 7.8, y: 7.6), CGPoint(x: 12, y: 3.8), CGPoint(x: 14.9, y: 7)])
            ctx.strokePath()
            ctx.fillEllipse(in: CGRect(x: 10.7, y: 2.5, width: 2.6, height: 2.6))

            ctx.translateBy(x: 12, y: 14)
            ctx.rotate(by: -6 * .pi / 180)
            ctx.translateBy(x: -12, y: -14)
            ctx.setLineWidth(1.8)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 4.2, y: 8.2, width: 15.6, height: 12), cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.strokePath()
            ctx.addLines(between: [CGPoint(x: 7, y: 18), CGPoint(x: 10.4, y: 14.4), CGPoint(x: 12.8, y: 16.6),
                                   CGPoint(x: 14.6, y: 15), CGPoint(x: 17.4, y: 18)])
            ctx.closePath()
            ctx.fillPath()
            ctx.fillEllipse(in: CGRect(x: 14.2, y: 10.6, width: 2.4, height: 2.4))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Framed"
        return image
    }
}

/// Borderless panel that can take key focus (for Esc and ⌘Q) without activating Framed, so the
/// app the user is in stays frontmost.
private final class MenuPanel: NSPanel {
    init(content: some View) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        contentView = NSHostingView(rootView: content) // sized to fit by MenuBarController on each open
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { MenuBarController.shared.closePanel() } // Esc
    override func resignKey() {
        super.resignKey()
        MenuBarController.shared.closePanel()
    }
}

// MARK: - Model

/// What the panel shows, re-read every time it opens.
@MainActor @Observable
final class MenuModel {
    struct Recent: Identifiable {
        let url: URL
        let thumbnail: NSImage?
        let date: Date?
        let pixelSize: String?
        var id: URL { url }
        /// Copied to the clipboard rather than saved; lives in Framed's cache, not the captures folder.
        var wasCopied: Bool { url.deletingLastPathComponent().standardizedFileURL == Exporter.copiedFolder.standardizedFileURL }
    }

    var recents: [Recent] = []
    var hasPermission = true
    var launchesAtLogin = false
    var shortcutsConflict = false
    var showsCaptureMenu = false
    @ObservationIgnored var close: () -> Void = {}
    @ObservationIgnored private var thumbnails: [URL: NSImage] = [:]

    func refresh() {
        showsCaptureMenu = false
        hasPermission = CGPreflightScreenCaptureAccess()
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        shortcutsConflict = SystemShortcuts.conflictsWithFramed
        let urls = Exporter.recentCaptures(limit: 3)
        thumbnails = thumbnails.filter { urls.contains($0.key) }
        recents = urls.map { url in
            if thumbnails[url] == nil { thumbnails[url] = Self.thumbnail(for: url) }
            return Recent(url: url, thumbnail: thumbnails[url], date: try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                          pixelSize: Self.pixelSize(of: url))
        }
    }

    // Each action closes the panel first; captures wait for it to disappear so it isn't captured.

    func captureArea() { close(); CaptureCoordinator.shared.captureInteractive(after: CaptureCoordinator.menuDismissDelay) }
    func captureWindow() { close(); CaptureCoordinator.shared.captureInteractive(after: CaptureCoordinator.menuDismissDelay, windowMode: true) }
    func captureScreen() { close(); CaptureCoordinator.shared.captureFullscreen(after: CaptureCoordinator.menuDismissDelay) }
    func allowScreenRecording() { close(); CaptureCoordinator.shared.requestPermission() }
    func open(_ recent: Recent) { close(); CaptureCoordinator.shared.openFile(recent.url) }
    func reveal(_ recent: Recent) { close(); NSWorkspace.shared.activateFileViewerSelecting([recent.url]) }
    func copy(_ recent: Recent) { close(); Exporter.copyFile(recent.url); MenuBarController.shared.flashConfirmation() }
    func openCapturesFolder() { close(); Exporter.revealCapturesFolder() }
    func takeOverShortcuts() { close(); SystemShortcuts.offerTakeover() }
    func quit() { NSApp.terminate(nil) }

    func setLaunchesAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            close()
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        launchesAtLogin = service.status == .enabled
    }

    /// "2880 × 1800", read from the PNG header without decoding it.
    private static func pixelSize(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width) × \(height)"
    }

    private static func thumbnail(for url: URL) -> NSImage? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 240] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

// MARK: - Views

private struct MenuPanelView: View {
    @Bindable var model: MenuModel
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private static let recentSlots = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !model.hasPermission {
                MenuRow(symbol: "exclamationmark.triangle.fill", title: "Allow Screen Recording…", tint: .sun, action: model.allowScreenRecording)
                    .padding(.top, 8)
            }

            PanelDivider().padding(.vertical, 12)

            HStack(alignment: .firstTextBaseline) {
                SectionLabel(title: "Recent")
                Spacer()
                Button("Open Folder", action: model.openCapturesFolder)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.sun)
                    .padding(.trailing, 4)
            }

            // Missing recents show as empty frames, so the list keeps its shape from the first capture.
            ForEach(model.recents) { RecentRow(recent: $0, model: model) }
            ForEach(model.recents.count..<max(Self.recentSlots, model.recents.count), id: \.self) { _ in PlaceholderRow() }

            PanelDivider().padding(.top, 10).padding(.bottom, 5)

            MenuRow(symbol: "power", title: "Launch at Login", action: { model.setLaunchesAtLogin(!model.launchesAtLogin) }) {
                PanelSwitch(isOn: model.launchesAtLogin)
            }
            if model.shortcutsConflict {
                MenuRow(symbol: "keyboard", title: "Use ⇧⌘3 / ⇧⌘4 for Framed…", action: model.takeOverShortcuts)
            }
            MenuRow(symbol: "rectangle.portrait.and.arrow.right", title: "Quit Framed", action: model.quit) {
                Text("⌘Q").foregroundStyle(Color.cream.opacity(0.45))
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 284)
        .background {
            ZStack {
                RadialGradient(colors: [.ink, .inkDeep], center: .top, startRadius: 0, endRadius: 320)
                DotGrid(spacing: 14)
            }
            .onTapGesture { model.showsCaptureMenu = false } // a click anywhere else dismisses the dropdown
        }
        // The capture dropdown floats over the recents, under the header's Capture button.
        .overlay(alignment: .topTrailing) {
            if model.showsCaptureMenu {
                CaptureMenu(model: model)
                    .padding(.top, 50)
                    .padding(.trailing, 12)
                    .transition(.scale(scale: 0.95, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.15), value: model.showsCaptureMenu)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Framed").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.cream)
                if let version { Text("Version \(version)").font(.system(size: 10.5)).foregroundStyle(Color.cream.opacity(0.55)) }
            }
            Spacer()
            CaptureSplitButton(model: model)
        }
    }
}

/// Terracotta split button: the main part captures an area (also Return), the chevron opens the
/// dropdown with all three capture modes.
private struct CaptureSplitButton: View {
    @Bindable var model: MenuModel
    @StateObject private var mainHover = HoverState()
    @StateObject private var chevronHover = HoverState()

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        HStack(spacing: 0) {
            Button(action: model.captureArea) {
                Label("Capture", systemImage: "rectangle.dashed")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.leading, 10)
                    .padding(.trailing, 9)
                    .frame(height: 28)
                    .background(.white.opacity(mainHover.isHovering ? 0.1 : 0))
                    .contentShape(Rectangle())
            }
            .keyboardShortcut(.defaultAction)
            .onHover { mainHover.isHovering = $0 }
            .help("Capture an area (⇧⌘4)")

            Rectangle().fill(Color.terracottaDeep.opacity(0.7)).frame(width: 1, height: 28)

            Button { model.showsCaptureMenu.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 28)
                    .background(.white.opacity(chevronHover.isHovering || model.showsCaptureMenu ? 0.1 : 0))
                    .contentShape(Rectangle())
            }
            .onHover { chevronHover.isHovering = $0 }
            .help("All capture modes")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.cream)
        .background(Color.terracotta)
        .clipShape(shape)
        .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)))
        .background(shape.fill(Color.terracottaDeep).offset(y: 2))
    }
}

/// The split button's dropdown: the three capture modes in a small framed card.
private struct CaptureMenu: View {
    let model: MenuModel

    var body: some View {
        VStack(spacing: 1) {
            CaptureOption(symbol: "rectangle.dashed", title: "Area", shortcut: "⇧⌘4", action: model.captureArea)
            CaptureOption(symbol: "macwindow", title: "Window", shortcut: "Space", action: model.captureWindow)
            CaptureOption(symbol: "display", title: "Screen", shortcut: "⇧⌘3", action: model.captureScreen)
        }
        .padding(3)
        .frame(width: 168)
        .framedPanel(cornerRadius: 7)
    }
}

private struct CaptureOption: View {
    let symbol: String
    let title: String
    let shortcut: String
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        let isOn = hover.isHovering
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 16)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(shortcut).font(.system(size: 10.5)).opacity(0.55)
            }
            .foregroundStyle(isOn ? Color.cream : Color.ink)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(isOn ? Color.terracotta : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
    }
}

/// Display-only on/off switch in the theme's colors. The system Toggle draws as inactive (grey)
/// because the panel never activates Framed; the surrounding row handles the click.
private struct PanelSwitch: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Color.terracotta : Color.cream.opacity(0.18))
            .overlay(Capsule().strokeBorder(isOn ? Color.terracottaDeep : .clear))
            .frame(width: 28, height: 16)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle().fill(.white).frame(width: 12, height: 12).shadow(color: .black.opacity(0.3), radius: 1, y: 0.5).padding(2)
            }
            .animation(.snappy(duration: 0.15), value: isOn)
    }
}

/// A recent capture as a row: framed thumbnail, when, and how it left the editor. Click to reopen
/// it in the editor, drag it into any app, or right-click for more.
private struct RecentRow: View {
    let recent: MenuModel.Recent
    let model: MenuModel
    @StateObject private var hover = HoverState()

    var body: some View {
        Button { model.open(recent) } label: {
            HStack(spacing: 10) {
                FramedThumbnail {
                    Color.cream.opacity(0.4).overlay {
                        if let thumbnail = recent.thumbnail {
                            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.relative(recent.date)).font(.system(size: 12)).foregroundStyle(Color.cream)
                    HStack(spacing: 4) {
                        Image(systemName: recent.wasCopied ? "doc.on.doc" : "arrow.down.to.line").font(.system(size: 8.5, weight: .semibold))
                        Text([recent.wasCopied ? "Copied" : "Saved", recent.pixelSize].compactMap { $0 }.joined(separator: " · "))
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.cream.opacity(0.5))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(Color.cream.opacity(hover.isHovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
        .onDrag { NSItemProvider(contentsOf: recent.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open in Editor") { model.open(recent) }
            Button("Copy") { model.copy(recent) }
            if !recent.wasCopied { Button("Show in Finder") { model.reveal(recent) } }
        }
        .help(recent.wasCopied ? "Copied to the clipboard" : recent.url.lastPathComponent)
    }

    /// "2 min. ago", "yesterday"…
    private static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        if Date.now.timeIntervalSince(date) < 60 { return "Just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)).capitalizedFirstLetter
    }
}

/// An empty dashed frame standing in for a recent capture that doesn't exist yet.
private struct PlaceholderRow: View {
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.cream.opacity(0.16), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                .frame(width: FramedThumbnail<EmptyView>.width, height: FramedThumbnail<EmptyView>.height)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Color.cream.opacity(0.07)).frame(width: 90, height: 7)
                Capsule().fill(Color.cream.opacity(0.045)).frame(width: 60, height: 7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
    }
}

/// A small picture in a terracotta frame with a cream mat, like the app icon.
private struct FramedThumbnail<Content: View>: View {
    static var width: CGFloat { 54 } // outer size, shared with the empty placeholder frames
    static var height: CGFloat { 37 }
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: Self.width - 8, height: Self.height - 8)
            .clipShape(RoundedRectangle(cornerRadius: 1))
            .padding(2)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 2.5))
            .padding(2)
            .background(Color.terracotta, in: RoundedRectangle(cornerRadius: 4))
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.terracottaDeep).offset(y: 2))
            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}

/// A settings-style row with an icon, a title and an optional trailing accessory.
private struct MenuRow<Accessory: View>: View {
    let symbol: String
    let title: String
    var tint: Color = .cream
    let action: () -> Void
    @ViewBuilder var accessory: Accessory
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12)).frame(width: 16).opacity(0.75)
                Text(title).font(.system(size: 12.5))
                Spacer(minLength: 8)
                accessory.font(.system(size: 12))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(Color.cream.opacity(hover.isHovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.isHovering = $0 }
    }
}

extension MenuRow where Accessory == EmptyView {
    init(symbol: String, title: String, tint: Color = .cream, action: @escaping () -> Void) {
        self.init(symbol: symbol, title: title, tint: tint, action: action) { EmptyView() }
    }
}

/// Small uppercase heading for a panel section.
private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Color.cream.opacity(0.5))
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
    }
}

private struct PanelDivider: View {
    var body: some View {
        Rectangle().fill(Color.cream.opacity(0.1)).frame(height: 1)
    }
}

/// The editor's faint dot grid.
struct DotGrid: View {
    var spacing: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            var dots = Path()
            for x in stride(from: spacing / 2, to: size.width, by: spacing) {
                for y in stride(from: spacing / 2, to: size.height, by: spacing) {
                    dots.addEllipse(in: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                }
            }
            context.fill(dots, with: .color(.white.opacity(0.05)))
        }
    }
}
