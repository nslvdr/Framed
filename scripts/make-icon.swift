// Renders Framed's app icon (ink wall, terracotta picture frame) and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [preview.png]
// Colors match Sources/Framed/App/Theme.swift.
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let ink = color(0x2A2A33), inkDeep = color(0x121217)
let terracotta = color(0xD2693C), terracottaDeep = color(0x9A4220)
let cream = color(0xFBF3E6), sand = color(0xF6D8B0), clay = color(0xC98A5E), sun = color(0xF4A259)

/// Draws in a 100-unit, y-down design space; the body (5…95) maps onto the macOS 824 px icon grid.
func drawIcon(_ ctx: CGContext) {
    ctx.translateBy(x: 0, y: 1024)
    ctx.scaleBy(x: 1, y: -1)
    ctx.translateBy(x: 100, y: 100)
    ctx.scaleBy(x: 824 / 90, y: 824 / 90)
    ctx.translateBy(x: -5, y: -5)

    let body = roundedRect(CGRect(x: 5, y: 5, width: 90, height: 90), 20)

    // Body with the standard macOS drop shadow (y-down space, so +y is downward).
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -1.1), blur: 2.6, color: color(0x000000, 0.35))
    ctx.addPath(body)
    ctx.setFillColor(inkDeep)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let wall = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [ink, inkDeep] as CFArray, locations: nil)!
    ctx.drawLinearGradient(wall, start: CGPoint(x: 50, y: 5), end: CGPoint(x: 50, y: 95), options: [])
    ctx.restoreGState()

    // Hairline edge so the dark body still reads on a dark Dock.
    ctx.addPath(roundedRect(CGRect(x: 5.3, y: 5.3, width: 89.4, height: 89.4), 19.7))
    ctx.setStrokeColor(color(0xFFFFFF, 0.08))
    ctx.setLineWidth(0.6)
    ctx.strokePath()

    // String and nail.
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: 35, y: 37)); ctx.addLine(to: CGPoint(x: 50, y: 22)); ctx.addLine(to: CGPoint(x: 65, y: 37))
    ctx.setStrokeColor(terracottaDeep.copy(alpha: 0.75)!)
    ctx.setLineWidth(1.6)
    ctx.strokePath()
    ctx.setFillColor(terracottaDeep)
    ctx.fillEllipse(in: CGRect(x: 47.4, y: 18.4, width: 5.2, height: 5.2))

    // The tilted frame.
    ctx.saveGState()
    ctx.translateBy(x: 50, y: 52)
    ctx.rotate(by: -6 * .pi / 180)
    ctx.translateBy(x: -50, y: -52)
    let frame = CGRect(x: 23, y: 31, width: 54, height: 44)
    ctx.addPath(roundedRect(frame.offsetBy(dx: 1.5, dy: 3), 5))
    ctx.setFillColor(terracottaDeep.copy(alpha: 0.35)!)
    ctx.fillPath()
    ctx.addPath(roundedRect(frame, 5))
    ctx.setFillColor(terracotta)
    ctx.fillPath()
    ctx.addPath(roundedRect(frame, 5))
    ctx.setStrokeColor(terracottaDeep.copy(alpha: 0.5)!)
    ctx.setLineWidth(1.4)
    ctx.strokePath()
    ctx.addPath(roundedRect(CGRect(x: 30, y: 37, width: 40, height: 31), 2.5))
    ctx.setFillColor(cream)
    ctx.fillPath()

    // The picture: sand sky, sun, clay hills.
    let picture = CGRect(x: 34, y: 40, width: 32, height: 24)
    ctx.addPath(roundedRect(picture, 1.5))
    ctx.clip()
    ctx.setFillColor(sand)
    ctx.fill(picture)
    ctx.setFillColor(sun)
    ctx.fillEllipse(in: CGRect(x: 55, y: 43, width: 8, height: 8))
    let hills = CGMutablePath()
    hills.move(to: CGPoint(x: 30, y: 60))
    hills.addQuadCurve(to: CGPoint(x: 50, y: 57), control: CGPoint(x: 42, y: 49))
    hills.addQuadCurve(to: CGPoint(x: 70, y: 54), control: CGPoint(x: 58, y: 65))
    hills.addLine(to: CGPoint(x: 70, y: 70))
    hills.addLine(to: CGPoint(x: 30, y: 70))
    hills.closeSubpath()
    ctx.addPath(hills)
    ctx.setFillColor(clay)
    ctx.fillPath()
    ctx.restoreGState()

    // Sparkle.
    let sparkle = CGMutablePath()
    sparkle.addLines(between: [CGPoint(x: 80, y: 18), CGPoint(x: 81.6, y: 21.6), CGPoint(x: 85.2, y: 23.2), CGPoint(x: 81.6, y: 24.8),
                               CGPoint(x: 80, y: 28.4), CGPoint(x: 78.4, y: 24.8), CGPoint(x: 74.8, y: 23.2), CGPoint(x: 78.4, y: 21.6)])
    sparkle.closeSubpath()
    ctx.addPath(sparkle)
    ctx.setFillColor(color(0xFFFFFF, 0.9))
    ctx.fillPath()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = context.cgContext
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon(ctx)
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appending(path: "icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appending(path: "icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 1 { try render(size: 1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
