import AppKit
import SwiftUI

/// Builds the fixed-size floating panel, keeps it centered above the Dock,
/// and makes everything outside the glass click-through.
final class SurfacePresenter: NSObject {
    let state = SurfaceState()
    private let panel: SurfacePanel
    private var mouseMonitors: [Any] = []
    private var isScrolling = false
    private var wheelIdleTask: Task<Void, Never>?

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
        state.makeKey = { [weak self] in self?.panel.makeKey() }

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
        if let scroll = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            self.handleScroll(event)
            return nil
        }) {
            mouseMonitors.append(scroll)
        }
    }

    /// The panel only accepts mouse events while the cursor is over the visible glass,
    /// or while a scroll gesture that started on the glass is still in progress.
    private func updateMousePassthrough() {
        if isScrolling { return }
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

    // MARK: - Scroll gestures

    /// Translates AppKit scroll events into finger-direction began / changed / ended events.
    /// Trackpads report phases; plain mouse wheels don't, so their gestures end after an idle gap.
    private func handleScroll(_ event: NSEvent) {
        // Momentum after the fingers lift isn't part of the gesture.
        guard event.momentumPhase.isEmpty else { return }

        let scale = event.hasPreciseScrollingDeltas ? 1 : SurfaceGesture.wheelLineScale
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let delta = CGSize(
            width: event.scrollingDeltaX * scale * sign,
            height: event.scrollingDeltaY * scale * sign
        )

        if event.phase.contains(.began) {
            beginScroll()
        } else if event.phase.contains(.changed) {
            if !isScrolling { beginScroll() }
            state.onScroll?(SurfaceScrollEvent(phase: .changed, delta: delta))
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            endScroll()
        } else if event.phase.isEmpty {
            if !isScrolling { beginScroll() }
            state.onScroll?(SurfaceScrollEvent(phase: .changed, delta: delta))
            wheelIdleTask?.cancel()
            wheelIdleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(SurfaceGesture.wheelIdle))
                guard !Task.isCancelled else { return }
                self?.endScroll()
            }
        }
    }

    private func beginScroll() {
        isScrolling = true
        state.onScroll?(SurfaceScrollEvent(phase: .began))
    }

    private func endScroll() {
        guard isScrolling else { return }
        wheelIdleTask?.cancel()
        isScrolling = false
        state.onScroll?(SurfaceScrollEvent(phase: .ended))
        updateMousePassthrough()
    }
}
