import AppKit
import Testing
@testable import Framed

@MainActor
struct EditorDocumentTests {
    /// A solid 200×100 px image treated as a 2x capture (100×50 pt).
    private func makeDocument() -> EditorDocument {
        let ctx = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(NSColor.blue.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        return EditorDocument(image: ctx.makeImage()!, scale: 2)
    }

    @Test func renderMatchesCropAtFullPixelResolution() throws {
        let doc = makeDocument()
        #expect(doc.render()?.width == 200)
        doc.setCrop(CGRect(x: 10.2, y: 5, width: 40, height: 20.1))
        let image = try #require(doc.render())
        #expect(image.width == 81) // snapped outward to whole pixels: 20…101
        #expect(image.height == 41)
    }

    @Test func undoAndRedoRestoreAnnotationsAndCrop() {
        let doc = makeDocument()
        doc.add(Annotation(kind: .step(center: .zero, number: 1), color: .red))
        doc.setCrop(CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(doc.nextStepNumber == 2)

        doc.undo()
        #expect(doc.state.crop == doc.imageBounds)
        doc.undo()
        #expect(doc.state.annotations.isEmpty)
        #expect(!doc.canUndo)

        doc.redo()
        #expect(doc.state.annotations.count == 1)
        doc.add(Annotation(kind: .rect(.zero), color: .red))
        #expect(!doc.canRedo) // a new edit clears redo
    }

    @Test func savedFileNameIsSortableAndFilesystemSafe() {
        let date = Date(timeIntervalSince1970: 0)
        let name = Exporter.fileName(for: date)
        #expect(name.hasPrefix("Framed ") && name.hasSuffix(".png"))
        #expect(!name.contains(":") && !name.contains("/"))
    }
}
