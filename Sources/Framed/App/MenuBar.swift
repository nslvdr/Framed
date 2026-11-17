import AppKit
import ServiceManagement
import SwiftUI

/// The menu bar icon and its menu. The menu is rebuilt each time it opens, so permission state,
/// recent captures and the login-item toggle are always current.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private var thumbnails: [URL: NSImage] = [:]
    private var flashTask: Task<Void, Never>?

    private static let icon = symbol("viewfinder", label: "Framed")
    private static let thumbnailSize = CGSize(width: 40, height: 26)
    private static let recentLimit = 5

    /// Call once at launch.
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "FramedStatusItem" // keeps the position the user ⌘-drags it to
        item.button?.image = Self.icon
        item.button?.toolTip = "Framed"
        let menu = NSMenu()
        menu.showsStateColumn = false // no empty checkmark gutter; toggles show state in the icon column instead
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Briefly swaps the icon for a checkmark, confirming a copy or save after the editor closes.
    func flashConfirmation() {
        guard let button = statusItem?.button else { return }
        flashTask?.cancel()
        button.image = Self.symbol("checkmark.circle.fill", label: "Done")
        flashTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            button.image = Self.icon
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem()
        header.view = Self.headerView()
        menu.addItem(header)
        menu.addItem(.separator())

        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(item("Allow Screen Recording…", symbol: "exclamationmark.triangle", action: #selector(allowScreenRecording)))
            menu.addItem(.separator())
        }

        menu.addItem(item("Capture Area", symbol: "rectangle.dashed", action: #selector(captureArea), key: "4", modifiers: [.command, .shift]))
        menu.addItem(item("Capture Window", symbol: "macwindow", action: #selector(captureWindow)))
        menu.addItem(item("Capture Screen", symbol: "display", action: #selector(captureScreen), key: "3", modifiers: [.command, .shift]))

        menu.addItem(.separator())
        let recents = Exporter.recentCaptures(limit: Self.recentLimit)
        thumbnails = thumbnails.filter { recents.contains($0.key) }
        if !recents.isEmpty {
            menu.addItem(.sectionHeader(title: "Recent"))
            recents.forEach { addRecent($0, to: menu) }
        }
        menu.addItem(item("Open Captures Folder", symbol: "folder", action: #selector(openCapturesFolder)))

        menu.addItem(.separator())
        let launchesAtLogin = SMAppService.mainApp.status == .enabled
        let login = item("Launch at Login", symbol: "checkmark", action: #selector(toggleLaunchAtLogin))
        if !launchesAtLogin { login.image = NSImage(size: login.image?.size ?? .zero) } // keeps titles aligned
        menu.addItem(login)
        if SystemShortcuts.conflictsWithFramed {
            menu.addItem(item("Use ⇧⌘3 and ⇧⌘4 for Framed…", action: #selector(takeOverShortcuts)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Quit Framed", action: #selector(quit), key: "q", modifiers: .command))
    }

    /// A recent capture opens in the editor; holding ⌥ turns it into "Show in Finder".
    private func addRecent(_ url: URL, to menu: NSMenu) {
        let thumbnail = thumbnail(for: url)
        let open = item(Self.relativeName(for: url), action: #selector(openRecent))
        open.image = thumbnail
        open.representedObject = url
        open.subtitle = Self.pixelSize(of: url)
        open.toolTip = url.lastPathComponent
        menu.addItem(open)

        let reveal = item("Show in Finder", action: #selector(revealRecent))
        reveal.image = thumbnail
        reveal.representedObject = url
        reveal.keyEquivalentModifierMask = .option
        reveal.isAlternate = true
        menu.addItem(reveal)
    }

    private func item(_ title: String, symbol: String? = nil, action: Selector,
                      key: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        if let symbol { item.image = Self.symbol(symbol, label: title) }
        return item
    }

    // MARK: Actions

    @objc private func captureArea() { CaptureCoordinator.shared.captureInteractive(after: CaptureCoordinator.menuDismissDelay) }
    @objc private func captureWindow() { CaptureCoordinator.shared.captureInteractive(after: CaptureCoordinator.menuDismissDelay, windowMode: true) }
    @objc private func captureScreen() { CaptureCoordinator.shared.captureFullscreen(after: CaptureCoordinator.menuDismissDelay) }
    @objc private func allowScreenRecording() { CaptureCoordinator.shared.requestPermission() }
    @objc private func openCapturesFolder() { Exporter.revealCapturesFolder() }
    @objc private func takeOverShortcuts() { SystemShortcuts.offerTakeover() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        CaptureCoordinator.shared.openFile(url)
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    /// Non-interactive header row: app icon, name and version.
    private static func headerView() -> NSView {
        let view = NSHostingView(rootView: MenuHeader())
        view.frame.size = view.fittingSize
        view.autoresizingMask = .width // stretch to the menu's width
        return view
    }

    // MARK: Images

    private static func symbol(_ name: String, label: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)
        image?.isTemplate = true
        return image
    }

    /// Fixed-size rounded thumbnail (aspect-fit), cached per file, so recent rows line up.
    private func thumbnail(for url: URL) -> NSImage? {
        if let cached = thumbnails[url] { return cached }
        let size = Self.thumbnailSize
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceThumbnailMaxPixelSize: size.width * 3] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }

        let fit = min(size.width / CGFloat(cgImage.width), size.height / CGFloat(cgImage.height))
        let drawn = CGSize(width: CGFloat(cgImage.width) * fit, height: CGFloat(cgImage.height) * fit)
        let rect = CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                          width: drawn.width, height: drawn.height).integral
        let image = NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSGraphicsContext.current?.cgContext.draw(cgImage, in: rect)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        thumbnails[url] = image
        return image
    }

    /// "2880 × 1800", read from the PNG header without decoding it.
    private static func pixelSize(of url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return "\(width) × \(height)"
    }

    /// "2 minutes ago", "yesterday"… from the file's creation date.
    private static func relativeName(for url: URL) -> String {
        guard let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate else { return url.lastPathComponent }
        if Date.now.timeIntervalSince(date) < 60 { return "Just now" }
        return date.formatted(.relative(presentation: .named)).capitalizedFirstLetter
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}

private struct MenuHeader: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage) // AppIcon.icns from the bundle
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Framed").font(.system(size: 13, weight: .semibold))
                if let version { Text("Version \(version)").font(.system(size: 11)).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 11) // the icon carries ~3 pt of transparent margin
        .padding(.vertical, 6)
        .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
    }
}
