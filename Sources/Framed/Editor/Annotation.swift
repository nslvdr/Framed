import AppKit

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, rect, text, pen, highlighter, pixelate, step, crop

    var id: Self { self }

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .rect: "Rectangle"
        case .text: "Text"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .pixelate: "Pixelate"
        case .step: "Numbered Step"
        case .crop: "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rect: "rectangle"
        case .text: "textformat"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .pixelate: "checkerboard.rectangle"
        case .step: "1.circle"
        case .crop: "crop"
        }
    }

    /// Single-key shortcut in the editor.
    var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .rect: "r"
        case .text: "t"
        case .pen: "p"
        case .highlighter: "h"
        case .pixelate: "b"
        case .step: "n"
        case .crop: "c"
        }
    }

    /// Whether the tool draws markup that has a color and size.
    var isStyled: Bool { ![.select, .pixelate, .crop].contains(self) }
}

/// Thin / medium / bold. Scales stroke width, text size and step badge size.
enum StrokeSize: Int, CaseIterable, Identifiable {
    case thin, medium, bold
    var id: Self { self }
    var factor: CGFloat { [0.6, 1, 1.6][rawValue] }
    var title: String { ["Thin", "Medium", "Bold"][rawValue] }
}

/// A markup element. All geometry is in image points with a top-left origin.
struct Annotation: Identifiable {
    enum Kind {
        case arrow(from: CGPoint, to: CGPoint)
        case rect(CGRect)
        case pen([CGPoint])
        case highlighter([CGPoint])
        case pixelate(CGRect)
        case step(center: CGPoint, number: Int)
        case text(origin: CGPoint, string: String)

        /// Whether color and size mean anything for this kind.
        var isStyled: Bool {
            if case .pixelate = self { false } else { true }
        }
    }

    let id = UUID()
    var kind: Kind
    var color: NSColor
    var size: StrokeSize = .medium

    // MARK: Metrics

    var lineWidth: CGFloat {
        let base: CGFloat = switch kind {
        case .arrow: 6
        case .highlighter: 20
        default: 4
        }
        return base * size.factor
    }

    var stepRadius: CGFloat { 15 * (1 + (size.factor - 1) * 0.6) }

    static func font(for size: StrokeSize) -> NSFont {
        .systemFont(ofSize: 24 * size.factor, weight: .bold)
    }

    var textAttributes: [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 3
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        return [.font: Self.font(for: size), .foregroundColor: color, .shadow: shadow]
    }

    /// Whether a just-drawn annotation is big enough to keep (filters accidental clicks).
    var isMeaningful: Bool {
        switch kind {
        case .arrow(let a, let b): hypot(b.x - a.x, b.y - a.y) >= 6
        case .rect(let r), .pixelate(let r): r.width >= 3 && r.height >= 3
        case .pen(let pts), .highlighter(let pts): pts.count >= 2
        case .step: true
        case .text(_, let s): !s.isEmpty
        }
    }

    // MARK: Selection geometry

    /// Area covered on screen, used for the selection outline.
    var bounds: CGRect {
        switch kind {
        case .arrow(let a, let b): CGRect(corners: a, b).insetBy(dx: -lineWidth, dy: -lineWidth)
        case .rect(let r): r.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .pixelate(let r): r
        case .pen(let pts), .highlighter(let pts): Self.boundingBox(pts).insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .step(let c, _): CGRect(x: c.x - stepRadius, y: c.y - stepRadius, width: stepRadius * 2, height: stepRadius * 2)
        case .text(let origin, let string): CGRect(origin: origin, size: NSAttributedString(string: string, attributes: textAttributes).size())
        }
    }

    /// Whether `p` touches the annotation. Rectangles are hit on their outline only,
    /// so markup inside them stays clickable.
    func contains(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .arrow(let a, let b):
            return Self.distance(p, toSegment: a, b) <= lineWidth + tolerance
        case .rect(let r):
            let outer = r.insetBy(dx: -(lineWidth / 2 + tolerance), dy: -(lineWidth / 2 + tolerance))
            let inner = r.insetBy(dx: lineWidth / 2 + tolerance, dy: lineWidth / 2 + tolerance)
            return outer.contains(p) && (inner.isNull || !inner.contains(p))
        case .pen(let pts), .highlighter(let pts):
            return zip(pts, pts.dropFirst()).contains { Self.distance(p, toSegment: $0, $1) <= lineWidth / 2 + tolerance }
        case .pixelate, .step, .text:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        var copy = self
        copy.kind = switch kind {
        case .arrow(let a, let b): .arrow(from: move(a), to: move(b))
        case .rect(let r): .rect(r.offsetBy(dx: dx, dy: dy))
        case .pixelate(let r): .pixelate(r.offsetBy(dx: dx, dy: dy))
        case .pen(let pts): .pen(pts.map(move))
        case .highlighter(let pts): .highlighter(pts.map(move))
        case .step(let c, let n): .step(center: move(c), number: n)
        case .text(let o, let s): .text(origin: move(o), string: s)
        }
        return copy
    }

    /// Draggable points: arrow endpoints, or rectangle corners (clockwise from top-left).
    var handles: [CGPoint] {
        switch kind {
        case .arrow(let a, let b): [a, b]
        case .rect(let r), .pixelate(let r):
            [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        default: []
        }
    }

    /// Returns a copy with handle `index` (from `handles`) dragged to `p`.
    func movingHandle(_ index: Int, to p: CGPoint) -> Annotation {
        var copy = self
        switch kind {
        case .arrow(let a, let b):
            copy.kind = index == 0 ? .arrow(from: p, to: b) : .arrow(from: a, to: p)
        case .rect:
            copy.kind = .rect(CGRect(corners: handles[(index + 2) % 4], p))
        case .pixelate:
            copy.kind = .pixelate(CGRect(corners: handles[(index + 2) % 4], p))
        default:
            break
        }
        return copy
    }

    private static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .null }
        return pts.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Draws annotations into a context whose coordinate space is y-down (flipped)
/// and whose current NSGraphicsContext is flipped too (needed for text).
enum AnnotationRenderer {
    static func draw(_ annotation: Annotation, in ctx: CGContext, pixelated: CGImage?, imageBounds: CGRect) {
        let color = annotation.color.cgColor
        let softShadow = NSColor.black.withAlphaComponent(0.3).cgColor
        ctx.saveGState()
        defer { ctx.restoreGState() }

        switch annotation.kind {
        case .arrow(let from, let to):
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: softShadow)
            ctx.addPath(arrowPath(from: from, to: to, width: annotation.lineWidth))
            ctx.setFillColor(color)
            ctx.fillPath()

        case .rect(let rect):
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: softShadow)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(annotation.lineWidth)
            ctx.strokePath()

        case .pen(let points):
            stroke(points, in: ctx, color: color, width: annotation.lineWidth)

        case .highlighter(let points):
            // Multiply makes markers look natural, but would make white (and near-white) invisible.
            ctx.setBlendMode(isLight(annotation.color, threshold: 0.9) ? .normal : .multiply)
            stroke(points, in: ctx, color: annotation.color.withAlphaComponent(0.4).cgColor, width: annotation.lineWidth)

        case .pixelate(let rect):
            guard let pixelated else { return }
            ctx.clip(to: rect)
            drawImage(pixelated, in: imageBounds, ctx: ctx)

        case .step(let center, let number):
            let radius = annotation.stepRadius
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(.white)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: radius * 1.05, weight: .bold),
                .foregroundColor: contrastingTextColor(for: annotation.color),
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))

        case .text(let origin, let string):
            NSAttributedString(string: string, attributes: annotation.textAttributes).draw(at: origin)
        }
    }

    /// Filled, tapered arrow whose tip lands exactly on `to`.
    static func arrowPath(from start: CGPoint, to end: CGPoint, width w: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return path }
        let u = CGPoint(x: dx / length, y: dy / length)      // along the arrow
        let n = CGPoint(x: -u.y, y: u.x)                     // perpendicular
        let headLength = min(length, w * 4)
        let headHalf = w * 2.2
        let base = CGPoint(x: end.x - u.x * headLength, y: end.y - u.y * headLength)
        func offset(_ p: CGPoint, _ d: CGFloat) -> CGPoint { CGPoint(x: p.x + n.x * d, y: p.y + n.y * d) }

        path.addLines(between: [
            offset(start, w * 0.2), offset(base, w * 0.55), offset(base, headHalf), end,
            offset(base, -headHalf), offset(base, -w * 0.55), offset(start, -w * 0.2),
        ])
        path.closeSubpath()
        return path
    }

    /// Draws a CGImage upright inside a flipped context.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: rect)
        ctx.restoreGState()
    }

    private static func stroke(_ points: [CGPoint], in ctx: CGContext, color: CGColor, width: CGFloat) {
        guard points.count > 1 else { return }
        ctx.addLines(between: points)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
    }

    private static func contrastingTextColor(for color: NSColor) -> NSColor {
        isLight(color) ? .black : .white
    }

    /// Perceived luminance above `threshold` (0…1). Yellow is ~0.77, white 1.
    static func isLight(_ color: NSColor, threshold: CGFloat = 0.7) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent > threshold
    }
}
