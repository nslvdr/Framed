import SwiftUI

/// Framed's palette, taken from the app icon (scripts/make-icon.swift): an ink wall with a
/// terracotta frame. Terracotta replaces the system accent color throughout the app.
enum Theme {
    static let ink = NSColor(hex: 0x2A2A33)
    static let inkDeep = NSColor(hex: 0x121217)
    static let terracotta = NSColor(hex: 0xD2693C)
    static let terracottaDeep = NSColor(hex: 0x9A4220)
    static let cream = NSColor(hex: 0xFBF3E6)
    static let sand = NSColor(hex: 0xF6D8B0)
    static let clay = NSColor(hex: 0xC98A5E)
    static let sun = NSColor(hex: 0xF4A259)
}

extension Color {
    static let ink = Color(nsColor: Theme.ink)
    static let inkDeep = Color(nsColor: Theme.inkDeep)
    static let terracotta = Color(nsColor: Theme.terracotta)
    static let terracottaDeep = Color(nsColor: Theme.terracottaDeep)
    static let cream = Color(nsColor: Theme.cream)
    static let sand = Color(nsColor: Theme.sand)
    static let clay = Color(nsColor: Theme.clay)
    static let sun = Color(nsColor: Theme.sun)
}

// MARK: - Shared components

extension View {
    /// "Gallery" panel used by the dock and the options popover, styled like the app icon's picture
    /// frame: a cream mat in a thin terracotta frame whose darker bottom lip matches the active tool
    /// and the Save button.
    func framedPanel(cornerRadius: CGFloat, frameWidth: CGFloat = 3) -> some View {
        let mat = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let frame = RoundedRectangle(cornerRadius: cornerRadius + frameWidth, style: .continuous)
        return background(Color.cream, in: mat)
            .overlay(mat.strokeBorder(Color.terracottaDeep.opacity(0.18))) // mat sits slightly recessed
            .padding(frameWidth)
            .background(Color.terracotta, in: frame)
            .overlay(frame.strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)))
            .background(frame.fill(Color.terracottaDeep).offset(y: 3))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 10)
    }
}

/// Hover flag for a view. A StateObject rather than @State: the Command Line Tools ship without SwiftUI's macro plugin.
final class HoverState: ObservableObject {
    @Published var isHovering = false
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
