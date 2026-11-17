import AppKit
import Testing
@testable import Framed

/// Regression tests for the editor quirks found in the behaviour audit.
@MainActor
struct EditorBehaviorTests {
    private func makeDocument() -> EditorDocument {
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return EditorDocument(image: ctx.makeImage()!, scale: 1)
    }

    private func step(_ n: Int) -> Annotation {
        Annotation(kind: .step(center: .zero, number: n), color: .red)
    }

    @Test func deletingAStepNeverYieldsDuplicateNumbers() {
        let doc = makeDocument()
        let (one, two, three) = (step(1), step(2), step(3))
        [one, two, three].forEach(doc.add)
        doc.remove(two.id)
        #expect(doc.nextStepNumber == 4)
    }

    @Test func leavingCropAppliesPendingAdjustmentsAndCancelDropsThem() {
        let doc = makeDocument()
        doc.tool = .rect
        doc.tool = .crop
        doc.pendingCrop = CGRect(x: 10, y: 10, width: 50, height: 50)
        #expect(doc.visibleCrop.width == 50)
        doc.cancelCrop()
        #expect(doc.state.crop == doc.imageBounds)
        #expect(doc.tool == .rect) // back to the tool used before cropping

        doc.tool = .crop
        doc.pendingCrop = CGRect(x: 10, y: 10, width: 50, height: 50)
        doc.finishCrop()
        #expect(doc.state.crop == CGRect(x: 10, y: 10, width: 50, height: 50)) // applied synchronously
    }

    @Test func selectingShowsItsStyleAndRepickingItAddsNoUndoStep() {
        let doc = makeDocument()
        let arrow = Annotation(kind: .arrow(from: .zero, to: CGPoint(x: 40, y: 40)), color: .systemBlue, size: .bold)
        doc.add(arrow)
        doc.tool = .select
        doc.select(arrow)
        #expect(doc.color == .systemBlue && doc.size == .bold)

        doc.undo() // drop the add so only style changes would remain undoable
        doc.redo()
        doc.select(arrow)
        let undoable = doc.canUndo
        doc.setColor(.systemBlue)
        doc.undo()
        #expect(doc.state.annotations.isEmpty == true) // the only undo step was the add itself
        #expect(undoable)
    }

    @Test func savesNeverOverwriteEachOther() {
        let folder = URL(fileURLWithPath: "/tmp/framed")
        let taken: Set<String> = ["Framed x.png", "Framed x (2).png"]
        let url = Exporter.uniqueURL(in: folder, fileName: "Framed x.png") { taken.contains($0.lastPathComponent) }
        #expect(url.lastPathComponent == "Framed x (3).png")
    }
}

struct HighlighterBlendTests {
    @Test func onlyNearWhiteSkipsTheMultiplyBlend() {
        #expect(AnnotationRenderer.isLight(.white, threshold: 0.9))
        #expect(!AnnotationRenderer.isLight(.systemYellow, threshold: 0.9)) // yellow keeps the marker look
    }
}
