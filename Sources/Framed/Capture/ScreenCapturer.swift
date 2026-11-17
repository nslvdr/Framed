import AppKit
import ScreenCaptureKit

/// A full-resolution snapshot of one display, taken before the selection overlay appears.
struct FrozenDisplay {
    let screen: NSScreen
    let image: CGImage
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

/// An on-screen window that can be picked in the overlay. `frame` is in Cocoa global coordinates.
struct WindowTarget {
    let id: CGWindowID
    var frame: CGRect
}

enum CaptureError: LocalizedError {
    case windowNotFound
    var errorDescription: String? { "The window is no longer available." }
}

@MainActor
enum ScreenCapturer {
    /// Snapshots every display exactly as it looks, including any open Framed editors, so the
    /// capture matches what the user sees through the transparent overlay.
    static func freezeDisplays() async throws -> [FrozenDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        var result: [FrozenDisplay] = []
        for screen in NSScreen.screens {
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor)
            config.height = Int(screen.frame.height * screen.backingScaleFactor)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(FrozenDisplay(screen: screen, image: image))
        }
        return result
    }

    /// Normal-level windows (including Framed editors), ordered front to back, for hit-testing.
    static func windowsFrontToBack() -> [WindowTarget] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return info.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds),
                  rect.width > 20, rect.height > 20
            else { return nil }
            return WindowTarget(id: id, frame: Geometry.flipped(rect, primaryHeight: primaryHeight))
        }
    }

    /// Captures a single window on its own (unobstructed, transparent rounded corners).
    static func captureWindow(_ id: CGWindowID) async throws -> (image: CGImage, scale: CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.windowNotFound }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
