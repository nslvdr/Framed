import CoreGraphics
import Testing
@testable import Framed

struct GeometryTests {
    @Test func flipConvertsBetweenCoreGraphicsAndCocoaSpace() {
        let cg = CGRect(x: 10, y: 20, width: 100, height: 50)
        let cocoa = Geometry.flipped(cg, primaryHeight: 1000)
        #expect(cocoa == CGRect(x: 10, y: 930, width: 100, height: 50))
        #expect(Geometry.flipped(cocoa, primaryHeight: 1000) == cg)
    }

    @Test func pixelRectFlipsYAndScalesToRetina() {
        // A 2x display: 100×50 pt view backed by 200×100 px image.
        let rect = Geometry.pixelRect(forViewRect: CGRect(x: 10, y: 0, width: 20, height: 10),
                                      viewSize: CGSize(width: 100, height: 50), imageSize: CGSize(width: 200, height: 100))
        #expect(rect == CGRect(x: 20, y: 80, width: 40, height: 20)) // bottom of view = bottom of image
    }

    @Test func pixelRectIsClampedToImage() {
        let rect = Geometry.pixelRect(forViewRect: CGRect(x: -10, y: -10, width: 30, height: 30),
                                      viewSize: CGSize(width: 100, height: 100), imageSize: CGSize(width: 100, height: 100))
        #expect(rect == CGRect(x: 0, y: 80, width: 20, height: 20))
    }

    @Test func arrowTipLandsOnEndPoint() {
        let end = CGPoint(x: 120, y: 40)
        let path = AnnotationRenderer.arrowPath(from: CGPoint(x: 0, y: 0), to: end, width: 6)
        #expect(path.boundingBoxOfPath.maxX == end.x)
        #expect(path.contains(CGPoint(x: 60, y: 20)))
    }
}

struct CropEdgesTests {
    let crop = CGRect(x: 100, y: 100, width: 200, height: 100)

    @Test func detectsSidesAndCorners() {
        #expect(CropEdges.hit(CGPoint(x: 102, y: 150), rect: crop, tolerance: 5) == .left)
        #expect(CropEdges.hit(CGPoint(x: 298, y: 203), rect: crop, tolerance: 5) == [.right, .bottom])
        #expect(CropEdges.hit(CGPoint(x: 200, y: 150), rect: crop, tolerance: 5).isEmpty) // interior draws a new crop
    }

    @Test func movingAnEdgeKeepsTheOthersAndStaysInImage() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(CropEdges.left.resizing(crop, by: CGVector(dx: -30, dy: 50), within: bounds) == CGRect(x: 70, y: 100, width: 230, height: 100))
        #expect(CropEdges([.right, .bottom]).resizing(crop, by: CGVector(dx: 500, dy: 500), within: bounds) == CGRect(x: 100, y: 100, width: 300, height: 200))
    }
}
