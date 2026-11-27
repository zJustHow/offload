import AppKit
import SwiftUI

/// Creates and tracks the app's windows. A menu-bar app has no Dock icon; while any of its windows
/// is open it becomes an ordinary app (so it shows in the Dock and Cmd-Tab and can take focus), and
/// goes back to the menu bar when the last one closes.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    var onClose: ((String) -> Void)?

    func isOpen(_ id: String) -> Bool { windows[id]?.isVisible == true }

    /// Brings the window forward, creating it on first use.
    func show<V: View>(_ id: String, title: String, size: CGSize, immersive: Bool = false, resizable: Bool = true, minSize: CGSize? = nil, @ViewBuilder content: () -> V) {
        if let w = windows[id] { w.makeKeyAndOrderFront(nil); activate(); return }
        var mask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { mask.insert(.resizable) }
        if immersive { mask.insert(.fullSizeContentView) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: mask, backing: .buffered, defer: false)
        w.title = title
        w.appearance = NSAppearance(named: .darkAqua)   // the app is dark, so native controls and menus must be too
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content())
        w.setContentSize(size)
        if let minSize { w.contentMinSize = minSize }
        if immersive {
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(calibratedWhite: 0.129, alpha: 1)
            if !resizable { w.standardWindowButton(.zoomButton)?.isHidden = true }
        }
        w.delegate = self
        w.center()
        windows[id] = w
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        activate()
    }

    func close(_ id: String) { windows[id]?.close() }

    private func activate() { NSApp.activate(ignoringOtherApps: true) }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, let id = windows.first(where: { $0.value === closing })?.key else { return }
        windows[id] = nil
        onClose?(id)
        if windows.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
