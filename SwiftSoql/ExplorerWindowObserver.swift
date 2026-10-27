import AppKit
import SwiftUI

/// Watches the explorer window it's in: saves the window's frame as it changes (see
/// `WindowFrame`), and keeps a window to work in when one closes. Closing the last org window
/// shows the list of orgs, and closing the list of orgs when no other window is open quits.
struct ExplorerWindowObserver: NSViewRepresentable {
    /// Whether the window is connected to an org, rather than showing the list of orgs.
    let isConnected: Bool
    /// Opens a window showing the list of orgs.
    let showOrgList: () -> Void

    func makeNSView(context: Context) -> NSView {
        ObserverView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? ObserverView else { return }
        view.isConnected = isConnected
        view.showOrgList = showOrgList
    }

    /// Every explorer window, to tell when the last one closes.
    private static let windows = NSHashTable<NSWindow>.weakObjects()
    /// Set as the app quits, when windows closing shouldn't open others.
    private static var isQuitting = false

    private final class ObserverView: NSView {
        var isConnected = false
        var showOrgList: () -> Void = {}
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            WindowFrame.restore(window)
            ExplorerWindowObserver.windows.add(window)
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated {
                        if let window { WindowFrame.save(window) }
                    }
                })
            }
            observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    if let self, let window { self.windowWillClose(window) }
                }
            })
            // The window the user was working in when they quit.
            observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    ExplorerWindowObserver.isQuitting = true
                    if let window, window.isMainWindow || NSApp.mainWindow == nil { WindowFrame.save(window) }
                }
            })
        }

        private func windowWillClose(_ window: NSWindow) {
            WindowFrame.save(window)
            guard !ExplorerWindowObserver.isQuitting else { return }
            // Minimized windows are still open.
            func isOpen(_ other: NSWindow) -> Bool { other !== window && (other.isVisible || other.isMiniaturized) }
            guard !ExplorerWindowObserver.windows.allObjects.contains(where: isOpen) else { return }
            if isConnected {
                // Once this window is gone, so the new one isn't placed relative to it.
                DispatchQueue.main.async { [showOrgList] in showOrgList() }
            } else if !NSApp.windows.contains(where: { isOpen($0) && $0.styleMask.contains(.titled) && $0.sheetParent == nil }) {
                // The list of orgs was the last window.
                NSApp.terminate(nil)
            }
        }
    }
}
