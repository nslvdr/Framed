import AppKit

/// Which sides of the crop rectangle a drag moves. Bits match `NSCursor.FrameResizePosition`,
/// so a set of edges maps directly to the native resize cursor.
struct CropEdges: OptionSet {
    let rawValue: UInt
    static let top = CropEdges(rawValue: 1 << 0)
    static let left = CropEdges(rawValue: 1 << 1)
    static let bottom = CropEdges(rawValue: 1 << 2)
    static let right = CropEdges(rawValue: 1 << 3)

    /// Edges of `rect` within `tolerance` of `p` (two edges near a corner). Coordinates are y-down.
    static func hit(_ p: CGPoint, rect: CGRect, tolerance t: CGFloat) -> CropEdges {
        guard rect.insetBy(dx: -t, dy: -t).contains(p) else { return [] }
        var edges: CropEdges = []
        if abs(p.x - rect.minX) <= t { edges.insert(.left) } else if abs(p.x - rect.maxX) <= t { edges.insert(.right) }
        if abs(p.y - rect.minY) <= t { edges.insert(.top) } else if abs(p.y - rect.maxY) <= t { edges.insert(.bottom) }
        return edges
    }

    /// `rect` with these edges moved by `delta`, kept inside `bounds`.
    func resizing(_ rect: CGRect, by delta: CGVector, within bounds: CGRect) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if contains(.left) { minX += delta.dx }
        if contains(.right) { maxX += delta.dx }
        if contains(.top) { minY += delta.dy }
        if contains(.bottom) { maxY += delta.dy }
        return CGRect(corners: CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY)).intersection(bounds)
    }

    @MainActor var cursor: NSCursor {
        guard let position = NSCursor.FrameResizePosition(rawValue: rawValue) else { return .arrow }
        return .frameResize(position: position, directions: .all)
    }
}
