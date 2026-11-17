import AppKit
import CoreImage.CIFilterBuiltins
import Observation

/// One screenshot being annotated: the base image, markup, crop, undo history, and the
/// editor's current tool/style/selection. Geometry is in image points (pixels / scale), top-left origin.
@MainActor
@Observable
final class EditorDocument {
    struct State {
        var annotations: [Annotation] = []
        var crop: CGRect
    }

    static let palette: [NSColor] = [.systemRed, Theme.terracotta, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .white, .black]

    let image: CGImage
    let scale: CGFloat
    let imageBounds: CGRect
    @ObservationIgnored let pixelated: CGImage?

    private(set) var state: State
    private var undoStack: [State] = []
    private var redoStack: [State] = []

    var tool: Tool = .arrow {
        didSet {
            guard tool != oldValue else { return }
            if tool != .select { selectedID = nil }
            showsOptions = false
            if tool == .crop { toolBeforeCrop = oldValue }
            if oldValue == .crop, let pending = pendingCrop { // leaving crop applies its adjustments
                pendingCrop = nil
                setCrop(pending)
            }
        }
    }
    private(set) var color: NSColor = .systemRed
    private(set) var size: StrokeSize = .medium
    private(set) var selectedID: UUID?
    /// Whether the color/size popover above the dock is open.
    var showsOptions = false

    /// Edge adjustments made in the current crop session; applied when leaving crop mode,
    /// dropped by `cancelCrop`.
    var pendingCrop: CGRect?
    private(set) var toolBeforeCrop: Tool = .arrow

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = scale
        imageBounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        state = State(crop: imageBounds)
        pixelated = Self.makePixelated(image, blockSize: 12 * scale)
    }

    var selected: Annotation? { state.annotations.first { $0.id == selectedID } }

    /// Color and size apply to styled tools, or to a selected annotation.
    var hasStyleOptions: Bool { tool.isStyled || (tool == .select && selected != nil) }

    var isOptionsVisible: Bool { showsOptions && hasStyleOptions }

    /// The crop as currently shown, including pending crop-mode adjustments.
    var visibleCrop: CGRect { pendingCrop ?? state.crop }

    /// Applies pending crop adjustments and returns to the previous tool.
    func finishCrop() {
        if tool == .crop { tool = toolBeforeCrop }
    }

    /// Leaves crop mode, discarding adjustments that weren't applied.
    func cancelCrop() {
        pendingCrop = nil
        finishCrop()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// One past the highest step number, so deleting a step never produces duplicates.
    var nextStepNumber: Int {
        state.annotations.reduce(0) { highest, annotation in
            if case .step(_, let number) = annotation.kind { max(highest, number) } else { highest }
        } + 1
    }

    func add(_ annotation: Annotation) {
        apply { $0.annotations.append(annotation) }
    }

    /// Topmost annotation under `p`.
    func annotation(at p: CGPoint, tolerance: CGFloat) -> Annotation? {
        state.annotations.last { $0.contains(p, tolerance: tolerance) }
    }

    /// Selects an annotation (or clears the selection) and shows its style in the dock.
    func select(_ annotation: Annotation?) {
        selectedID = annotation?.id
        if let annotation { adoptStyle(of: annotation) }
    }

    /// Makes `annotation`'s color and size the current drawing style, without changing anything.
    func adoptStyle(of annotation: Annotation) {
        guard annotation.kind.isStyled else { return }
        color = annotation.color
        size = annotation.size
    }

    /// Sets the drawing color, and recolors the selected annotation if any.
    func setColor(_ color: NSColor) {
        self.color = color
        if selected?.color != color { updateSelected { $0.color = color } }
    }

    /// Sets the drawing size, and resizes the selected annotation if any.
    func setSize(_ size: StrokeSize) {
        self.size = size
        if selected?.size != size { updateSelected { $0.size = size } }
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        remove(id)
    }

    func remove(_ id: UUID) {
        apply { $0.annotations.removeAll { $0.id == id } }
        if selectedID == id { selectedID = nil }
    }

    /// Changes one annotation as a single undo step.
    func update(_ id: UUID, _ change: (inout Annotation) -> Void) {
        guard let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
        apply { change(&$0.annotations[index]) }
    }

    /// Starts a continuous edit (e.g. a drag); the whole gesture becomes one undo step.
    func beginLiveEdit() {
        undoStack.append(state)
        redoStack.removeAll()
    }

    /// Abandons a continuous edit, restoring the state from before `beginLiveEdit`.
    func cancelLiveEdit() {
        guard let previous = undoStack.popLast() else { return }
        state = previous
    }

    /// Replaces an annotation in place without recording undo; pair with `beginLiveEdit`.
    func replaceLive(_ annotation: Annotation) {
        guard let index = state.annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        state.annotations[index] = annotation
    }

    private func updateSelected(_ change: (inout Annotation) -> Void) {
        if let selectedID { update(selectedID, change) }
    }

    /// Sets the crop, snapped to whole pixels and clamped to the image.
    func setCrop(_ rect: CGRect) {
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        let snapped = CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
            .intersection(imageBounds)
        guard !snapped.isEmpty, snapped != state.crop else { return }
        apply { $0.crop = snapped }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
        dropStaleSelection()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        dropStaleSelection()
    }

    private func dropStaleSelection() {
        if selected == nil { selectedID = nil }
    }

    private func apply(_ change: (inout State) -> Void) {
        undoStack.append(state)
        redoStack.removeAll()
        change(&state)
    }

    // MARK: Rendering

    /// Draws the image and markup (plus an optional in-progress annotation, minus one being
    /// re-edited) in image-point space. Expects a flipped context with a flipped current NSGraphicsContext.
    func drawContent(in ctx: CGContext, draft: Annotation? = nil, hiding hiddenID: UUID? = nil) {
        AnnotationRenderer.drawImage(image, in: imageBounds, ctx: ctx)
        for annotation in state.annotations + [draft].compactMap({ $0 }) where annotation.id != hiddenID {
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
