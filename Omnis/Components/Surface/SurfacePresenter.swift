import AppKit
import SwiftUI

/// Builds the fixed-size floating panel, keeps it centered above the Dock,
/// and makes everything outside the glass click-through.
final class SurfacePresenter: NSObject {
    let state = SurfaceState()
    private let panel: SurfacePanel
    private var mouseMonitors: [Any] = []
    private var isScrolling = false
    /// Whether the current (or last) scroll gesture belongs to scrollable content.
    private var routesToContent = false
    private var pullPastTop: CGFloat = 0
    private var pullCommitted = false
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
        // Belongs to one Space at a time and is moved to each newly active one (see
        // `activeSpaceChanged`). Joining all Spaces would draw it on both desktops mid-swipe.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification,
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

    /// Follows the user to the new desktop: the panel stays behind on the old one as it slides
    /// away, then is brought over and materializes on the new one, so it's only ever shown once.
    @objc private func activeSpaceChanged() {
        let wasPresented = state.isPresented
        var instantly = Transaction()
        instantly.disablesAnimations = true
        withTransaction(instantly) { state.isPresented = false }
        position()  // the new desktop may be on another display
        panel.orderFrontRegardless()
        guard wasPresented else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        // Next pass, so the hidden state renders first and the materialize animation plays.
        DispatchQueue.main.async { [weak self] in
            self?.state.isPresented = true
            self?.updateMousePassthrough()
        }
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
            // Pass the event on to scrollable content; swallow it if it drove the surface gesture.
            return self.handleScroll(event) ? nil : event
        }) {
            mouseMonitors.append(scroll)
        }
    }

    /// The panel only accepts mouse events while the cursor is over the visible glass,
    /// or while a scroll gesture that started on the glass is still in progress.
    ///
    /// The window controls float above the glass, so the strip between them and the glass, and
    /// the controls themselves, count as being over the surface too; that keeps them showing
    /// (and clickable) as the pointer moves up to them.
    private func updateMousePassthrough() {
        if isScrolling { return }
        let location = NSEvent.mouseLocation
        let glass = glassScreenFrame
        let controls = screenFrame(of: state.controlsFrame)
        let reach = controls.isEmpty
            ? glass
            : glass.union(controls).union(CGRect(x: controls.minX, y: glass.maxY, width: controls.width, height: controls.minY - glass.maxY))
        let over = state.isPresented && (glass.contains(location) || (state.isHovering && reach.contains(location)))
        if state.isHovering != over { state.isHovering = over }
        let ignores = !over
        if panel.ignoresMouseEvents != ignores {
            panel.ignoresMouseEvents = ignores
        }
    }

    /// A frame in SwiftUI's top-left panel space, in bottom-left screen space.
    private func screenFrame(of rect: CGRect) -> CGRect {
        guard !rect.isEmpty else { return .zero }
        let frame = panel.frame
        return CGRect(x: frame.minX + rect.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
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

    /// Routes a scroll event and returns whether it was consumed by the surface gesture.
    ///
    /// Each gesture is routed once, when it starts: if the content has a scroll view, the whole
    /// gesture (momentum included) goes to it; otherwise it becomes finger-direction
    /// began / changed / ended events for collapse / expand. Trackpads report phases; plain
    /// mouse wheels don't, so their gestures end after an idle gap.
    private func handleScroll(_ event: NSEvent) -> Bool {
        let phase = event.phase

        // Momentum belongs to whichever side owned the gesture.
        if !event.momentumPhase.isEmpty { return !routesToContent }
        if phase.contains(.mayBegin) { return state.scrollableOwner == nil }

        let isWheel = phase.isEmpty
        let moves = isWheel || phase.contains(.changed)
        if phase.contains(.began) || (moves && !isScrolling) {
            beginScroll()
        }

        if moves {
            let scale = event.hasPreciseScrollingDeltas ? 1 : SurfaceGesture.wheelLineScale
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            let delta = CGSize(
                width: event.scrollingDeltaX * scale * sign,
                height: event.scrollingDeltaY * scale * sign
            )
            if routesToContent {
                // The content scrolls vertically; side pulls still reach the surface.
                trackPullPastTop(delta.height)
                state.onScroll?(SurfaceScrollEvent(phase: .changed, delta: delta, horizontalOnly: true))
            } else {
                state.onScroll?(SurfaceScrollEvent(phase: .changed, delta: delta))
            }
        }

        if isWheel {
            wheelIdleTask?.cancel()
            wheelIdleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(SurfaceGesture.wheelIdle))
                guard !Task.isCancelled else { return }
                self?.endScroll()
            }
        }

        let consumed = !routesToContent
        if phase.contains(.ended) || phase.contains(.cancelled) {
            endScroll()
        }
        return consumed
    }

    /// While the content is at its top, finger travel downward (beyond it) accumulates; once it
    /// passes `pullPastTopDistance` the surface collapses, at most once per gesture.
    /// The content's own elastic overscroll is too damped to measure this reliably.
    private func trackPullPastTop(_ fingerDown: CGFloat) {
        guard !pullCommitted else { return }
        if state.contentAtTop {
            pullPastTop = max(pullPastTop + fingerDown, 0)
        } else {
            pullPastTop = 0
        }
        if pullPastTop >= SurfaceGesture.pullPastTopDistance {
            pullCommitted = true
            state.onPullPastTop?()
        }
    }

    private func beginScroll() {
        isScrolling = true
        routesToContent = state.scrollableOwner != nil
        pullPastTop = 0
        pullCommitted = false
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
