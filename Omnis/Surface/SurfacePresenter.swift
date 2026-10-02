import AppKit
import SwiftUI

/// Builds the fixed-size floating panel, keeps it centered above the Dock,
/// and makes everything outside the glass click-through.
final class SurfacePresenter: NSObject {
    let state = SurfaceState()
    private let panel: SurfacePanel
    private var mouseMonitors: [Any] = []

    init<Content: View>(@ViewBuilder content: () -> Content) {
        panel = SurfacePanel(
            contentRect: CGRect(origin: .zero, size: SurfaceMetrics.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true

        let hostingView = NSHostingView(rootView: content().environment(state))
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = CGRect(origin: .zero, size: SurfaceMetrics.panelSize)
        panel.contentView = hostingView

        state.onGlassFrameChange = { [weak self] _ in self?.updateMousePassthrough() }

        position()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        installMouseMonitors()
    }

    func show() {
        orderFrontRegardless()
        // Lay out once in the hidden state so the materialize animation has a starting point.
        panel.contentView?.layoutSubtreeIfNeeded()
        state.isPresented = true
        updateMousePassthrough()
    }

    func hide() {
        state.isPresented = false
        updateMousePassthrough()
    }

    func orderFrontRegardless() {
        panel.orderFrontRegardless()
    }

    // MARK: - Positioning

    @objc private func screenParametersChanged() {
        position()
    }

    /// Centers the panel horizontally with the glass `dockGap` above the Dock.
    private func position() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = SurfaceMetrics.panelSize
        let origin = CGPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: visible.minY + SurfaceMetrics.dockGap - SurfaceMetrics.overshootMargin
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        updateMousePassthrough()
    }

    // MARK: - Click-through

    private func installMouseMonitors() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            self?.updateMousePassthrough()
        }) {
            mouseMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            self?.updateMousePassthrough()
            return event
        }) {
            mouseMonitors.append(local)
        }
    }

    /// The panel only accepts mouse events while the cursor is over the visible glass.
    private func updateMousePassthrough() {
        let ignores = !(state.isPresented && glassScreenFrame.contains(NSEvent.mouseLocation))
        if panel.ignoresMouseEvents != ignores {
            panel.ignoresMouseEvents = ignores
        }
    }

    /// Converts the glass frame from SwiftUI's top-left panel space to bottom-left screen space.
    private var glassScreenFrame: CGRect {
        let glass = state.glassFrame
        let frame = panel.frame
        return CGRect(
            x: frame.minX + glass.minX,
            y: frame.maxY - glass.maxY,
            width: glass.width,
            height: glass.height
        )
    }
}
