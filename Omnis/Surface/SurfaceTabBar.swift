import SwiftUI

/// Capsule glass tab bar: icon-over-label tabs on a selection pill. Like iOS, the pill can be
/// picked up and dragged to another tab. While lifted it becomes a native glass drop that
/// trails the pointer like water and stretches with its speed.
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

    private static var height: CGFloat { 52 }
    private static var inset: CGFloat { 4 }
    private static var tabWidth: CGFloat { 72 }
    private static var tabHeight: CGFloat { height - inset * 2 }
    private static var tabSpacing: CGFloat { -4 }      // neighbouring tabs overlap slightly
    private static var step: CGFloat { tabWidth + tabSpacing }

    private static var liftScale: CGFloat { 1.3 }       // drop size relative to the resting pill
    private static var maxStretch: CGFloat { 0.28 }
    private static var stretchSpeed: CGFloat { 1400 }   // pt/s of drag that reaches maxStretch
    private static var edgeGive: CGFloat { 14 }         // how far the drop can be pulled past the ends
    private static var flickCarry: CGFloat { 0.35 }     // share of the projected throw used on release
    private static var tapDistance: CGFloat { 4 }       // less movement than this is a tap

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
        return CGSize(
            width: Self.tabWidth * scale * (1 + stretch),
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
    }

    /// A soft fill at rest that turns into native glass while lifted.
    private var pill: some View {
        let size = dropSize
        return ZStack {
            Capsule().fill(.black.opacity(isLifted ? 0 : 0.6))
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
                    // A tap: the drop jumps to the tapped tab.
                    jump(to: Int((value.location.x / Self.step).rounded(.down)))
                }
            }
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
        settleTask = Task {
            try? await Task.sleep(for: .seconds(0.22))
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
