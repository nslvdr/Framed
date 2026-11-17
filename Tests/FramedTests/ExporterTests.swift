import Foundation
import Testing
@testable import Framed

struct ExporterTests {
    /// Creates `files` (name → seconds after a fixed date) in a fresh temporary folder.
    private func makeFolder(_ files: [(String, Double)]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for (name, offset) in files {
            let url = folder.appending(path: name)
            try Data().write(to: url)
            try FileManager.default.setAttributes([.creationDate: base.addingTimeInterval(offset)], ofItemAtPath: url.path)
        }
        return folder
    }

    @Test func recentCapturesMergeFoldersNewestPNGsFirst() throws {
        let saved = try makeFolder([("old.png", 0), ("new.png", 300), ("notes.txt", 500)])
        let copied = try makeFolder([("mid.png", 100)])
        defer { [saved, copied].forEach { try? FileManager.default.removeItem(at: $0) } }

        #expect(Exporter.recentCaptures(in: [saved, copied], limit: 2).map(\.lastPathComponent) == ["new.png", "mid.png"])
        #expect(Exporter.recentCaptures(in: [saved.appending(path: "missing")], limit: 5).isEmpty)
    }

    @Test func pruneKeepsOnlyTheNewest() throws {
        let folder = try makeFolder([("a.png", 0), ("b.png", 100), ("c.png", 200)])
        defer { try? FileManager.default.removeItem(at: folder) }

        Exporter.prune(folder, keeping: 2)
        #expect(Exporter.recentCaptures(in: [folder], limit: 5).map(\.lastPathComponent) == ["c.png", "b.png"])
    }
}
