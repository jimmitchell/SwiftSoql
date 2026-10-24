import AppKit
import SwiftUI

/// Remembers the toolbar's display mode (icons, text, or both) and gives new windows the same.
///
/// AppKit only saves it for toolbars that autosave their configuration, which SwiftUI's
/// non-customizable toolbars don't, so a choice made from the toolbar's context menu was lost on
/// relaunch.
struct ToolbarDisplayModeKeeper: NSViewRepresentable {
    static let setting = "toolbarDisplayMode"

    func makeNSView(context: Context) -> NSView {
        let view = WindowObservingView()
        view.onWindow = { context.coordinator.attach(to: $0) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        // SwiftUI can replace the toolbar when its items change; keep up with it.
        if let window = view.window { context.coordinator.attach(to: window) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private weak var window: NSWindow?
        private weak var toolbar: NSToolbar?
        private var lastMode: NSToolbar.DisplayMode?
        private var observer: NSObjectProtocol?

        /// Watches the window: its toolbar can appear after the window does, and changing the
        /// display mode from the toolbar's menu sends no notification of its own, so each window
        /// update checks both (a cheap comparison).
        func attach(to window: NSWindow) {
            guard window !== self.window else { return }
            self.window = window
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            check()
        }

        private func check() {
            guard let toolbar = window?.toolbar else { return }
            if toolbar !== self.toolbar {
                // A new toolbar: give it the saved mode.
                self.toolbar = toolbar
                let saved = AppDefaults.store.integer(forKey: ToolbarDisplayModeKeeper.setting)
                if let mode = NSToolbar.DisplayMode(rawValue: UInt(saved)), mode != .default {
                    toolbar.displayMode = mode
                }
                lastMode = toolbar.displayMode
            } else if toolbar.displayMode != lastMode {
                // Changed from the toolbar's menu: remember it.
                lastMode = toolbar.displayMode
                AppDefaults.store.set(Int(toolbar.displayMode.rawValue), forKey: ToolbarDisplayModeKeeper.setting)
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    /// Tells its owner which window it's in, once it's in one.
    private final class WindowObservingView: NSView {
        var onWindow: (NSWindow) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow(window) }
        }
    }
}
