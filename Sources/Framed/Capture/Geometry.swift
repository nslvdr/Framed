import CoreGraphics

extension CGRect {
    /// The rect spanned by two arbitrary corner points.
    init(corners a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

enum Geometry {
    /// Converts between CoreGraphics global space (origin top-left of the primary display, y down)
    /// and Cocoa global space (origin bottom-left, y up). The conversion is its own inverse.
    static func flipped(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Maps a rect in a y-up view showing `imageSize` pixels stretched over `viewSize` points
    /// to the matching (top-left origin) pixel rect, snapped outward to whole pixels.
    static func pixelRect(forViewRect r: CGRect, viewSize: CGSize, imageSize: CGSize) -> CGRect {
        let sx = imageSize.width / viewSize.width
        let sy = imageSize.height / viewSize.height
        return CGRect(x: r.minX * sx, y: (viewSize.height - r.maxY) * sy, width: r.width * sx, height: r.height * sy)
            .integral
            .intersection(CGRect(origin: .zero, size: imageSize))
    }
}
