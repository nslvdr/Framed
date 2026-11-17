import AppKit

/// Clipboard and file output for finished captures.
@MainActor
enum Exporter {
    nonisolated static var capturesFolder: URL {
        URL.picturesDirectory.appending(path: "Framed", directoryHint: .isDirectory)
    }

    /// Copies of captures that were copied rather than saved, so they still show up in the menu bar
    /// panel's "Recent". Lives in Caches and keeps only the newest `copiedLimit`.
    nonisolated static var copiedFolder: URL {
        URL.cachesDirectory.appending(path: "app.framed.Framed/Copied", directoryHint: .isDirectory)
    }
    nonisolated static let copiedLimit = 10

    /// PNG data tagged with the point size so Retina captures keep their 144 DPI.
    static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return rep.representation(using: .png, properties: [:])
    }

    /// Puts the capture on the clipboard and remembers it for "Recent".
    static func copy(_ image: CGImage, scale: CGFloat, date: Date = .now) {
        guard let png = pngData(image, scale: scale) else { return }
        putOnPasteboard(png)
        try? FileManager.default.createDirectory(at: copiedFolder, withIntermediateDirectories: true)
        let url = uniqueURL(in: copiedFolder, fileName: fileName(for: date)) { FileManager.default.fileExists(atPath: $0.path) }
        try? png.write(to: url, options: .atomic)
        prune(copiedFolder, keeping: copiedLimit)
    }

    /// Copies an existing PNG (a recent capture) to the clipboard again.
    static func copyFile(_ url: URL) {
        guard let png = try? Data(contentsOf: url) else { return }
        putOnPasteboard(png)
    }

    private static func putOnPasteboard(_ png: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
    }

    @discardableResult
    static func save(_ image: CGImage, scale: CGFloat, date: Date = .now) throws -> URL {
        guard let png = pngData(image, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: capturesFolder, withIntermediateDirectories: true)
        let url = uniqueURL(in: capturesFolder, fileName: fileName(for: date)) { FileManager.default.fileExists(atPath: $0.path) }
        try png.write(to: url, options: .atomic)
        return url
    }

    /// `fileName` in `folder`, or "name (2).png", "name (3).png"… if taken, so saves never overwrite.
    nonisolated static func uniqueURL(in folder: URL, fileName: String, exists: (URL) -> Bool) -> URL {
        let base = (fileName as NSString).deletingPathExtension, ext = (fileName as NSString).pathExtension
        var url = folder.appending(path: fileName)
        var counter = 2
        while exists(url) {
            url = folder.appending(path: "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return url
    }

    static func revealCapturesFolder() {
        try? FileManager.default.createDirectory(at: capturesFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(capturesFolder)
    }

    /// The newest PNGs across `folders` (saved and copied captures by default), newest first.
    nonisolated static func recentCaptures(in folders: [URL] = [capturesFolder, copiedFolder], limit: Int) -> [URL] {
        let files = folders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                          options: .skipsHiddenFiles)) ?? []
        }
        let dated = files.filter { $0.pathExtension.lowercased() == "png" }.map { url in
            (url, (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// Deletes all but the newest `count` PNGs in `folder`.
    nonisolated static func prune(_ folder: URL, keeping count: Int) {
        for url in recentCaptures(in: [folder], limit: .max).dropFirst(count) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// e.g. "Framed 2026-11-17 at 20.12.03.png"
    nonisolated static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Framed \(formatter.string(from: date)).png"
    }
}
