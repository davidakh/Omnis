import AppKit
import SwiftUI

/// Capsule glass tab bar: icon-over-label tabs on a selection pill. Like iOS, the pill can be
/// picked up and dragged to another tab. While lifted it becomes a native glass drop that
/// trails the pointer like water and stretches with its speed. Pressing the pill lifts it in
/// place, and scrolling over the bar steps the selection between tabs.
///
/// Layers, top to bottom: icons and labels, the glass pill, the bar's glass background.
/// The pill sits beneath the labels, so its glass never blurs them.
struct SurfaceTabBar<Value: Hashable>: View {
    struct Tab {
        let value: Value
        let title: String
        let symbol: String
    }

    let tabs: [Tab]
    @Binding var selection: Value

    /// Leading x of the pill (in row coordinates) while dragged; nil when resting on the selection.
    @State private var dragX: CGFloat?
    @State private var isLifted = false
    /// 0 at rest; grows with horizontal speed, elongating the drop along its motion.
    @State private var stretch: CGFloat = 0
    @State private var settleTask: Task<Void, Never>?
    /// When the current press touched down; nil between presses.
    @State private var pressStart: Date?
    @State private var isHovering = false
    @State private var scrollMonitor: Any?
    /// Scroll travel not yet spent on a tab step.
    @State private var scrollAccumulated: CGFloat = 0

    private static var height: CGFloat { 52 }
    private static var inset: CGFloat { 4 }
    private static var tabWidth: CGFloat { 72 }
    private static var tabHeight: CGFloat { height - inset * 2 }
    private static var tabSpacing: CGFloat { -4 }      // neighbouring tabs overlap slightly
    private static var step: CGFloat { tabWidth + tabSpacing }

    private static var liftScale: CGFloat { 1.3 }       // drop height relative to the resting pill
    private static var liftWidthScale: CGFloat { 1.1 }  // drop width relative to the resting pill
    private static var maxStretch: CGFloat { 0.28 }
    private static var stretchSpeed: CGFloat { 1400 }   // pt/s of drag that reaches maxStretch
    private static var edgeGive: CGFloat { 14 }         // how far the drop can be pulled past the ends
    private static var flickCarry: CGFloat { 0.35 }     // share of the projected throw used on release
    private static var tapDistance: CGFloat { 4 }       // less movement than this is a tap
    private static var scrollStep: CGFloat { 24 }       // trackpad scroll travel per tab step
    private static var minPressLift: Duration { .seconds(0.22) }  // a quick tap still shows the lift

    private static var lift: Animation { .spring(duration: 0.24, bounce: 0.25) }
    private static var follow: Animation { .spring(duration: 0.3, bounce: 0.3) }   // watery lag
    private static var settle: Animation { .spring(duration: 0.5, bounce: 0.42) }  // wobble into place

    private var selectedIndex: Int {
        tabs.firstIndex { $0.value == selection } ?? 0
    }

    private var maxPillX: CGFloat { CGFloat(max(tabs.count - 1, 0)) * Self.step }
    private var pillX: CGFloat { dragX ?? CGFloat(selectedIndex) * Self.step }

    private var dropSize: CGSize {
        let scale = isLifted ? Self.liftScale : 1
        let widthScale = isLifted ? Self.liftWidthScale : 1
        return CGSize(
            width: Self.tabWidth * widthScale * (1 + stretch),
            height: Self.tabHeight * scale * (1 - stretch * 0.2)
        )
    }

    var body: some View {
        labels                                              // top: icons and labels
            .background(alignment: .leading) { pill }      // middle: the glass pill
            .contentShape(Capsule())
            .gesture(dragGesture)
            .padding(Self.inset)
            .background {                                   // bottom: the bar's glass
                Color.clear.glassEffect(.clear.interactive(), in: Capsule())
            }
            .onHover { isHovering = $0 }
            .onAppear(perform: startScrollMonitor)
            .onDisappear(perform: stopScrollMonitor)
    }

    /// A soft fill at rest that turns into native glass while lifted.
    private var pill: some View {
        let size = dropSize
        return ZStack {
            Capsule().fill(.black.opacity(isLifted ? 0 : 0.4))
            GlassSurface(radius: size.height / 2, style: .lens)
                .opacity(isLifted ? 1 : 0)
        }
        .frame(width: size.width, height: size.height)
        .offset(x: pillX + (Self.tabWidth - size.width) / 2)
        .allowsHitTesting(false)
    }

    private var labels: some View {
        HStack(spacing: Self.tabSpacing) {
            ForEach(tabs, id: \.value) { tab in
                VStack(spacing: 1) {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .symbolVariant(tab.value == selection ? .fill : .none)
                        .animation(.smooth(duration: 0.2), value: selection)
                    Text(tab.title)
                        .font(.system(size: 8, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .frame(width: Self.tabWidth, height: Self.tabHeight)
            }
        }
    }

    // MARK: - Interaction

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if pressStart == nil { press(at: value.startLocation) }
                guard abs(value.translation.width) >= Self.tapDistance || dragX != nil else { return }
                settleTask?.cancel()
                if !isLifted { withAnimation(Self.lift) { isLifted = true } }
                let speed = min(abs(value.velocity.width) / Self.stretchSpeed, 1)
                withAnimation(Self.follow) {
                    dragX = rubberBanded(value.location.x - Self.tabWidth / 2)
                    stretch = speed * Self.maxStretch
                }
            }
            .onEnded { value in
                defer { pressStart = nil }
                if let dragX {
                    // Drop on the tab the throw is heading for.
                    let thrown = dragX + (value.predictedEndLocation.x - value.location.x) * Self.flickCarry
                    select(index: Int((thrown / Self.step).rounded()))
                    withAnimation(Self.settle) {
                        self.dragX = nil
                        isLifted = false
                        stretch = 0
                    }
                } else {
                    // Released without dragging: keep the drop up long enough to be seen.
                    let held = pressStart.map { Duration.seconds(Date.now.timeIntervalSince($0)) } ?? .zero
                    settleDown(after: Self.minPressLift - held)
                }
            }
    }

    /// Touch-down lifts the drop immediately, sliding it to the pressed tab if it isn't there.
    private func press(at location: CGPoint) {
        pressStart = .now
        settleTask?.cancel()
        withAnimation(Self.lift) { isLifted = true }
        let index = Int((location.x / Self.step).rounded(.down))
        if tabs.indices.contains(index), index != selectedIndex {
            withAnimation(Self.follow) { select(index: index) }
        }
    }

    // MARK: - Scrolling

    /// SwiftUI has no scroll-wheel modifier, so watch the window's scroll events and consume
    /// the horizontal ones that land while the pointer is over the bar. Vertical scrolls pass
    /// through to whatever is behind it.
    private func startScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard isHovering, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
            handleScroll(event)
            return nil
        }
    }

    private func stopScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    private func handleScroll(_ event: NSEvent) {
        // Momentum would skip across several tabs; only direct scrolling moves the pill.
        guard event.momentumPhase.isEmpty else { return }
        if event.phase.contains(.began) { scrollAccumulated = 0 }

        // Negated so the pill follows the fingers rather than the content direction.
        let delta = -event.scrollingDeltaX

        let step: Int
        if event.hasPreciseScrollingDeltas {
            // Trackpad: spend accumulated travel one tab at a time.
            scrollAccumulated += delta
            guard abs(scrollAccumulated) >= Self.scrollStep else { return }
            step = scrollAccumulated < 0 ? 1 : -1
            scrollAccumulated = 0
        } else {
            // Horizontal wheel or tilt: each notch is one tab.
            step = delta < 0 ? 1 : -1
        }
        jump(to: selectedIndex + step)
    }

    /// Follows freely between the end tabs, resisting like elastic beyond them.
    private func rubberBanded(_ x: CGFloat) -> CGFloat {
        func give(_ overshoot: CGFloat) -> CGFloat {
            Self.edgeGive * (1 - 1 / (overshoot / Self.edgeGive * 0.5 + 1))
        }
        if x < 0 { return -give(-x) }
        if x > maxPillX { return maxPillX + give(x - maxPillX) }
        return x
    }

    private func jump(to index: Int) {
        guard tabs.indices.contains(index), index != selectedIndex else { return }
        settleTask?.cancel()
        withAnimation(Self.lift) {
            isLifted = true
            stretch = Self.maxStretch * 0.6
        }
        withAnimation(Self.follow) { select(index: index) }
        settleDown(after: Self.minPressLift)
    }

    private func settleDown(after delay: Duration) {
        settleTask?.cancel()
        settleTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            withAnimation(Self.settle) {
                isLifted = false
                stretch = 0
            }
        }
    }

    private func select(index: Int) {
        guard !tabs.isEmpty else { return }
        selection = tabs[min(max(index, 0), tabs.count - 1)].value
    }
}

extension GlassStyle {
    /// Untinted clear glass with lensing, for the tab bar's lifted pill.
    static let lens = GlassStyle(variant: 2, tint: 0, scrim: 0, lensing: true)
}
