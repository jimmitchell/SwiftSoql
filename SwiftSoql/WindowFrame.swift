import AppKit
import SwiftUI

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

/// Saves the frame of the window it's in as the window changes, and when the app quits.
struct WindowFrameSaver: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        SaverView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class SaverView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            WindowFrame.restore(window)
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated {
                        if let window { WindowFrame.save(window) }
                    }
                })
            }
            // The window the user was working in when they quit.
            observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    if let window, window.isMainWindow || NSApp.mainWindow == nil { WindowFrame.save(window) }
                }
            })
        }
    }
}
