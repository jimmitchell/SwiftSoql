import AppKit

/// Remembers the size and place of the org window last moved, resized, closed or open at quit,
/// so the next launch opens its first window there.
///
/// macOS reopens windows where they were only when it restores them at launch, which is off on
/// Macs where "Close windows when quitting an application" is set; SwiftUI otherwise opens a
/// window group's windows at their default size.
enum WindowFrame {
    private static let key = "windowFrame"
    /// Whether this launch's first window has been given the saved frame.
    private static var hasRestored = false

    /// Gives the launch's first window the saved frame, if it's still on a screen. This is done
    /// with AppKit as the window gets its content, before it shows: SwiftUI's window placement
    /// positions windows on the display it picks, so can't put one back on another screen.
    static func restore(_ window: NSWindow) {
        guard !hasRestored else { return }
        hasRestored = true
        guard let text = AppDefaults.store.string(forKey: key) else { return }
        let frame = NSRectFromString(text)
        guard frame.width >= 200, frame.height >= 150,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        window.setFrame(frame, display: false)
    }

    static func save(_ window: NSWindow) {
        // A full-screen window's frame is the screen's, not the one to come back to.
        guard window.isVisible, !window.styleMask.contains(.fullScreen) else { return }
        AppDefaults.store.set(NSStringFromRect(window.frame), forKey: key)
    }
}
