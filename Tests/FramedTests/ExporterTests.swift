import Foundation
import Testing
@testable import Framed

struct ExporterTests {
    @Test func recentCapturesAreNewestPNGsFirst() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for (name, offset) in [("old.png", 0.0), ("new.png", 300), ("mid.png", 100), ("notes.txt", 500)] {
            let url = folder.appending(path: name)
            try Data().write(to: url)
            try FileManager.default.setAttributes([.creationDate: base.addingTimeInterval(offset)], ofItemAtPath: url.path)
        }

        #expect(Exporter.recentCaptures(in: folder, limit: 2).map(\.lastPathComponent) == ["new.png", "mid.png"])
        #expect(Exporter.recentCaptures(in: folder.appending(path: "missing"), limit: 5).isEmpty)
    }
}
