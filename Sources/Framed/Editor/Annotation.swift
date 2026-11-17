import AppKit

enum Tool: String, CaseIterable, Identifiable {
    case arrow, rect, text, pen, highlighter, pixelate, step, crop

    var id: Self { self }

    var title: String {
        switch self {
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
}

/// A markup element. All geometry is in image points with a top-left origin.
struct Annotation {
    enum Kind {
        case arrow(from: CGPoint, to: CGPoint)
        case rect(CGRect)
        case pen([CGPoint])
        case highlighter([CGPoint])
        case pixelate(CGRect)
        case step(center: CGPoint, number: Int)
        case text(origin: CGPoint, string: String)
    }

    var kind: Kind
    var color: NSColor

    static var textFont: NSFont { .systemFont(ofSize: 24, weight: .bold) }

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
}

/// Draws annotations into a context whose coordinate space is y-down (flipped)
/// and whose current NSGraphicsContext is flipped too (needed for text).
enum AnnotationRenderer {
    static func draw(_ annotation: Annotation, in ctx: CGContext, pixelated: CGImage?, imageBounds: CGRect) {
        let color = annotation.color.cgColor
        ctx.saveGState()
        defer { ctx.restoreGState() }

        switch annotation.kind {
        case .arrow(let from, let to):
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
            ctx.addPath(arrowPath(from: from, to: to, width: 6))
            ctx.setFillColor(color)
            ctx.fillPath()

        case .rect(let rect):
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.setStrokeColor(color)
            ctx.setLineWidth(4)
            ctx.strokePath()

        case .pen(let points):
            stroke(points, in: ctx, color: color, width: 4)

        case .highlighter(let points):
            ctx.setBlendMode(.multiply)
            stroke(points, in: ctx, color: annotation.color.withAlphaComponent(0.4).cgColor, width: 20)

        case .pixelate(let rect):
            guard let pixelated else { return }
            ctx.clip(to: rect)
            drawImage(pixelated, in: imageBounds, ctx: ctx)

        case .step(let center, let number):
            let radius: CGFloat = 15
            let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setFillColor(color)
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(.white)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))
            let label = NSAttributedString(string: "\(number)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .bold),
                .foregroundColor: contrastingTextColor(for: annotation.color),
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))

        case .text(let origin, let string):
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 3
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            NSAttributedString(string: string, attributes: [
                .font: Annotation.textFont,
                .foregroundColor: annotation.color,
                .shadow: shadow,
            ]).draw(at: origin)
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
        guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.7 ? .black : .white
    }
}
