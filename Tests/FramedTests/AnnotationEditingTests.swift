import AppKit
import Testing
@testable import Framed

@MainActor
struct AnnotationEditingTests {
    private func makeDocument() -> EditorDocument {
        let ctx = CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return EditorDocument(image: ctx.makeImage()!, scale: 2)
    }

    @Test func rectangleIsHitOnItsOutlineOnly() {
        let rect = Annotation(kind: .rect(CGRect(x: 10, y: 10, width: 100, height: 60)), color: .red)
        #expect(rect.contains(CGPoint(x: 10, y: 40), tolerance: 2))
        #expect(!rect.contains(CGPoint(x: 60, y: 40), tolerance: 2)) // interior stays clickable for markup beneath
    }

    @Test func draggingACornerKeepsTheOppositeCornerFixed() {
        let rect = Annotation(kind: .rect(CGRect(x: 10, y: 10, width: 100, height: 60)), color: .red)
        let resized = rect.movingHandle(2, to: CGPoint(x: 150, y: 100)) // bottom-right
        guard case .rect(let r) = resized.kind else { Issue.record("kind changed"); return }
        #expect(r == CGRect(x: 10, y: 10, width: 140, height: 90))
        #expect(resized.id == rect.id)
    }

    @Test func movingAnAnnotationIsOneUndoStep() throws {
        let doc = makeDocument()
        let arrow = Annotation(kind: .arrow(from: .zero, to: CGPoint(x: 50, y: 50)), color: .red)
        doc.add(arrow)

        doc.beginLiveEdit()
        for step in 1...10 { doc.replaceLive(arrow.offsetBy(dx: CGFloat(step), dy: 0)) }
        guard case .arrow(let from, _) = try #require(doc.state.annotations.first).kind else { return }
        #expect(from.x == 10)

        doc.undo()
        guard case .arrow(let restored, _) = try #require(doc.state.annotations.first).kind else { return }
        #expect(restored.x == 0)
    }

    @Test func styleChangesApplyToTheSelectedAnnotation() {
        let doc = makeDocument()
        let step = Annotation(kind: .step(center: CGPoint(x: 20, y: 20), number: 1), color: .red)
        doc.add(step)
        doc.tool = .select
        doc.select(step)

        doc.setColor(.systemBlue)
        doc.setSize(.bold)
        #expect(doc.selected?.color == .systemBlue)
        #expect(doc.selected?.size == .bold)

        doc.tool = .arrow // leaving Select clears the selection
        #expect(doc.selectedID == nil)
    }
}

@MainActor
struct EditorStateTests {
    @Test func switchingToolsClosesTheOptionsPopover() {
        let ctx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let doc = EditorDocument(image: ctx.makeImage()!, scale: 1)
        doc.showsOptions = true
        #expect(doc.isOptionsVisible)
        doc.tool = .crop
        #expect(!doc.showsOptions) // no hidden-but-open popover swallowing Esc in crop mode
        doc.showsOptions = true
        #expect(!doc.isOptionsVisible) // crop has no options to show
    }
}
