import AppKit

/// Clipboard and file output for finished captures.
@MainActor
enum Exporter {
    static var capturesFolder: URL {
        URL.picturesDirectory.appending(path: "Framed", directoryHint: .isDirectory)
    }

    /// PNG data tagged with the point size so Retina captures keep their 144 DPI.
    static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return rep.representation(using: .png, properties: [:])
    }

    static func copy(_ image: CGImage, scale: CGFloat) {
        guard let png = pngData(image, scale: scale) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
    }

    @discardableResult
    static func save(_ image: CGImage, scale: CGFloat, date: Date = .now) throws -> URL {
        guard let png = pngData(image, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: capturesFolder, withIntermediateDirectories: true)
        let url = capturesFolder.appending(path: fileName(for: date))
        try png.write(to: url, options: .atomic)
        return url
    }

    static func revealCapturesFolder() {
        try? FileManager.default.createDirectory(at: capturesFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(capturesFolder)
    }

    /// e.g. "Framed 2026-11-17 at 20.12.03.png"
    nonisolated static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Framed \(formatter.string(from: date)).png"
    }
}
