import SwiftUI

/// Framed's palette, taken from the app icon (scripts/make-icon.swift): an ink wall with a
/// terracotta frame. Terracotta replaces the system accent color throughout the app.
enum Theme {
    static let ink = NSColor(hex: 0x2A2A33)
    static let inkDeep = NSColor(hex: 0x121217)
    static let terracotta = NSColor(hex: 0xD2693C)
    static let terracottaDeep = NSColor(hex: 0x9A4220)
    static let cream = NSColor(hex: 0xFBF3E6)
}

extension Color {
    static let ink = Color(nsColor: Theme.ink)
    static let inkDeep = Color(nsColor: Theme.inkDeep)
    static let terracotta = Color(nsColor: Theme.terracotta)
    static let cream = Color(nsColor: Theme.cream)
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
