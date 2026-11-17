import AppKit

/// Lets Framed set the cursor while another app stays active (the selection overlay never
/// activates Framed). Uses the private "SetsCursorInBackground" window-server connection
/// property, looked up at runtime so a missing symbol degrades to a no-op.
enum BackgroundCursor {
    private typealias DefaultConnection = @convention(c) () -> Int32
    private typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    /// Call once at launch.
    static func enable() {
        let handle = dlopen(nil, RTLD_NOW)
        guard let connectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
              let setPropertySymbol = dlsym(handle, "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
        let setProperty = unsafeBitCast(setPropertySymbol, to: SetConnectionProperty.self)
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}
