import AppKit
import CoreImage.CIFilterBuiltins
import Observation

/// One screenshot being annotated: the base image, markup, crop, and undo history.
/// Geometry is in image points (pixels / scale) with a top-left origin.
@MainActor
@Observable
final class EditorDocument {
    struct State {
        var annotations: [Annotation] = []
        var crop: CGRect
    }

    static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black]

    let image: CGImage
    let scale: CGFloat
    let imageBounds: CGRect
    @ObservationIgnored let pixelated: CGImage?

    private(set) var state: State
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    var tool: Tool = .arrow
    var color: NSColor = .systemRed

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        imageBounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        state = State(crop: imageBounds)
        pixelated = Self.makePixelated(image, blockSize: 12 * scale)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var nextStepNumber: Int {
        state.annotations.count { if case .step = $0.kind { true } else { false } } + 1
    }

    func add(_ annotation: Annotation) {
        apply { $0.annotations.append(annotation) }
    }

    /// Sets the crop, snapped to whole pixels and clamped to the image.
    func setCrop(_ rect: CGRect) {
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        let snapped = CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
            .intersection(imageBounds)
        guard !snapped.isEmpty else { return }
        apply { $0.crop = snapped }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
    }

    private func apply(_ change: (inout State) -> Void) {
        undoStack.append(state)
        redoStack.removeAll()
        change(&state)
    }

    // MARK: Rendering

    /// Draws the image and markup (plus an optional in-progress annotation) in image-point space.
    /// Expects a flipped context with a flipped current NSGraphicsContext.
    func drawContent(in ctx: CGContext, draft: Annotation? = nil) {
        AnnotationRenderer.drawImage(image, in: imageBounds, ctx: ctx)
        for annotation in state.annotations + [draft].compactMap({ $0 }) {
            AnnotationRenderer.draw(annotation, in: ctx, pixelated: pixelated, imageBounds: imageBounds)
        }
    }

    /// Renders the cropped, annotated result at full pixel resolution.
    func render() -> CGImage? {
        let crop = state.crop
        let width = Int((crop.width * scale).rounded()), height = Int((crop.height * scale).rounded())
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -crop.minX, y: -crop.minY)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        drawContent(in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func makePixelated(_ image: CGImage, blockSize: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(blockSize)
        filter.center = .zero
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        return CIContext().createCGImage(output, from: input.extent)
    }
}
