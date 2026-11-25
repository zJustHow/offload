import AppKit
import Combine
import SwiftUI

/// A borderless, transparent panel that can take keyboard focus (so you can type to the assistant)
/// without activating the app or stealing focus from what you were doing.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// By default AppKit pushes a window out of the menu-bar band; this panel exists to sit in it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Lets clicks fall through everywhere except the visible surface, so the large transparent panel
/// never blocks the menu bar or the windows under it.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRect: () -> CGRect = { .zero }
    override func hitTest(_ point: NSPoint) -> NSView? {
        interactiveRect().contains(convert(point, from: superview)) ? super.hitTest(point) : nil
    }
    required init(rootView: Content) { super.init(rootView: rootView) }
    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) { fatalError("not used") }
}

/// Owns the panel that hosts `NotchView`, keeps it glued to the notch (also when displays change),
/// and turns clicks on the notch into an `onNotchClick` callback while the assistant is hidden.
@MainActor
public final class NotchWindowController {
    public let model: NotchModel
    public var onNotchClick: (() -> Void)?

    private var panel: NotchPanel?
    private var clickMonitor: Any?
    private var moveMonitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var phaseSub: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    private(set) public var geometry: NotchGeometry

    public init(model: NotchModel) {
        self.model = model
        self.geometry = Self.currentGeometry()
    }

    /// The screen with a hardware notch if there is one, otherwise the main screen.
    public static func currentGeometry() -> NotchGeometry {
        let screens = NSScreen.screens
        let screen = screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? screens.first
        guard let s = screen else { return NotchGeometry.compute(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), safeAreaTop: 0, topLeft: nil, topRight: nil) }
        return NotchGeometry.compute(screenFrame: s.frame, safeAreaTop: s.safeAreaInsets.top, topLeft: s.auxiliaryTopLeftArea, topRight: s.auxiliaryTopRightArea)
    }

    public func install() {
        guard panel == nil else { return }
        let hosting = PassthroughHostingView(rootView: NotchView(model: model, geometry: geometry))
        hosting.interactiveRect = { [weak self] in self?.model.interactiveRect ?? .zero }
        // The window's size is ours alone: SwiftUI content (including a transition caught mid-scale)
        // must not resize it.
        hosting.sizingOptions = []
        let p = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = hosting
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // The system's pop-in zoom would fight the surface's own animation (and leaves the window
        // scaled when it is shown without activating the app).
        p.animationBehavior = .none
        // Above the menu bar, so it can cover the notch band.
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.ignoresMouseEvents = true
        panel = p
        reposition()

        phaseSub = model.$phase.sink { [weak self] phase in self?.phaseChanged(phase) }

        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })

        // Clicking the notch opens the assistant. Global monitors see mouse events in other apps
        // without any special permission.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.phase == .hidden, self.geometry.contains(NSEvent.mouseLocation) else { return }
                self.onNotchClick?()
            }
        }
        // While visible, the panel only accepts the mouse over its surface; elsewhere it is invisible to it.
        let update: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.updateMousePassthrough() } }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: update) { moveMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { e in update(e); return e }) { moveMonitors.append(l) }
    }

    public func uninstall() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        moveMonitors.forEach(NSEvent.removeMonitor); moveMonitors = []
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        phaseSub = nil; hideTask?.cancel()
        panel?.orderOut(nil); panel = nil
    }

    public func present(mode: NotchModel.Mode? = nil) { model.present(mode: mode) }

    /// For diagnostics: the panel's real frame and window level.
    public var debugDescription: String {
        guard let p = panel else { return "no panel" }
        let layerInfo = p.contentView?.layer.map { "layer.transform=\($0.transform.m11),\($0.transform.m22) layer.frame=\($0.frame)" } ?? "no layer"
        return "contentView=\(String(describing: p.contentView?.frame)) \(layerInfo) alpha=\(p.alphaValue) backing=\(p.backingScaleFactor) frame=\(p.frame) level=\(p.level.rawValue) visible=\(p.isVisible) animationBehavior=\(p.animationBehavior.rawValue) screen=\(String(describing: p.screen?.frame))"
    }

    // MARK: internals

    private func reposition() {
        let previous = geometry
        geometry = Self.currentGeometry()
        guard let panel else { return }
        let size = NotchView.canvas
        panel.setFrame(NSRect(x: geometry.rect.midX - size.width / 2, y: geometry.screenFrame.maxY - size.height, width: size.width, height: size.height), display: true)
        // Replacing the root view mid-update is risky; only do it when the display really changed.
        if geometry != previous, let hosting = panel.contentView as? PassthroughHostingView<NotchView> { hosting.rootView = NotchView(model: model, geometry: geometry) }
    }

    private func phaseChanged(_ phase: NotchModel.Phase) {
        guard let panel else { return }
        hideTask?.cancel()
        if phase == .hidden {
            // Let the collapse animation play before the window goes away.
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled, let self, self.model.phase == .hidden else { return }
                self.panel?.orderOut(nil)
                self.panel?.ignoresMouseEvents = true
            }
            return
        }
        if !panel.isVisible { reposition(); panel.orderFrontRegardless() }
        if phase == .input { panel.makeKeyAndOrderFront(nil) }
        updateMousePassthrough()
    }

    private func updateMousePassthrough() {
        guard let panel, panel.isVisible else { return }
        let r = model.interactiveRect
        let screenRect = NSRect(x: panel.frame.minX + r.minX, y: panel.frame.maxY - r.maxY, width: r.width, height: r.height)
        panel.ignoresMouseEvents = !screenRect.contains(NSEvent.mouseLocation)
    }
}

// MARK: - Whole-display glow

@MainActor
final class EdgeGlowState: ObservableObject { @Published var visible = false }

private struct EdgeGlowHost: View {
    @ObservedObject var state: EdgeGlowState
    var body: some View { ScreenEdgeGlowView(visible: state.visible).padding(1) }
}

/// A click-through glow around every display, shown while the assistant is operating the Mac.
@MainActor
public final class ScreenEdgeGlowController {
    private var panels: [NSPanel] = []
    private let state = EdgeGlowState()
    private var hideTask: Task<Void, Never>?

    public init() {}

    public func show() {
        hideTask?.cancel()
        if panels.isEmpty {
            for screen in NSScreen.screens {
                let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                p.contentView = NSHostingView(rootView: EdgeGlowHost(state: state))
                p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
                p.ignoresMouseEvents = true
                p.level = .statusBar
                p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                p.setFrame(screen.frame, display: true)
                p.orderFrontRegardless()
                panels.append(p)
            }
        }
        state.visible = true
    }

    public func hide() {
        state.visible = false
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled, let self, !self.state.visible else { return }
            self.panels.forEach { $0.orderOut(nil) }
            self.panels = []
        }
    }
}
