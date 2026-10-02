import SwiftUI

/// Shared state between the presenter (AppKit) and the host (SwiftUI).
@Observable
final class SurfaceState {
    var isPresented = false

    /// The glass's current frame in panel (SwiftUI, top-left origin) coordinates.
    @ObservationIgnored var glassFrame: CGRect = .zero {
        didSet { onGlassFrameChange?(glassFrame) }
    }
    @ObservationIgnored var onGlassFrameChange: ((CGRect) -> Void)?

    /// Makes the panel key so text fields can take focus without a click.
    @ObservationIgnored var makeKey: (() -> Void)?

    /// Receives scroll gestures over the glass, forwarded by the presenter.
    @ObservationIgnored var onScroll: ((SurfaceScrollEvent) -> Void)?
}

/// A scroll gesture over the glass. `delta` is in points and follows the fingers
/// (SwiftUI axes: positive height = down), regardless of the natural-scrolling setting.
struct SurfaceScrollEvent {
    enum Phase { case began, changed, ended }

    var phase: Phase
    var delta: CGSize = .zero
}

/// Morphing glass container. Measures its content and springs the glass to fit it:
/// a capsule while short, a rounded rectangle once taller.
///
/// Scrolling over the glass makes it follow the scroll vector; scrolling far enough down
/// calls `onCollapse`, far enough up calls `onExpand`, and the glass bows back into place.
struct SurfaceHost<Content: View>: View {
    let id: AnyHashable
    var onCollapse: (() -> Void)?
    var onExpand: (() -> Void)?
    var showsGrabber: Bool
    @ViewBuilder let content: () -> Content

    @Environment(SurfaceState.self) private var surface: SurfaceState?

    @State private var surfaceWidth = SurfaceMetrics.minSide
    @State private var surfaceHeight = SurfaceMetrics.minSide
    @State private var target = CGSize(width: SurfaceMetrics.minSide, height: SurfaceMetrics.minSide)
    @State private var morphCount = 0
    @State private var morphPeak: CGFloat = 0
    @State private var followTask: Task<Void, Never>?
    @State private var currentID: AnyHashable?
    @State private var naturalSizes: [AnyHashable: CGSize] = [:]

    @State private var scrollTravel: CGSize = .zero
    @State private var scrollOffset: CGSize = .zero
    @State private var scrollCommitted = false

    init(
        id: AnyHashable,
        onCollapse: (() -> Void)? = nil,
        onExpand: (() -> Void)? = nil,
        showsGrabber: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.id = id
        self.onCollapse = onCollapse
        self.onExpand = onExpand
        self.showsGrabber = showsGrabber
        self.content = content
    }

    private var isPresented: Bool { surface?.isPresented ?? true }

    /// Uniform scale while following a vertical scroll: shrinks toward collapse (down),
    /// grows toward expand (up).
    private var scrollScale: CGFloat {
        1 - scrollOffset.height * SurfaceGesture.stretch
    }

    var body: some View {
        SpillWidth(width: surfaceWidth, height: surfaceHeight) {
            ZStack {
                ZStack {
                    content()
                        .fixedSize()
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { [id] in measured($0, for: id) }
                        .id(id)
                        .transition(SurfaceSwapTransition())
                }
                .animation(SurfaceMotion.content, value: id)

                // Fills the glass frame so the grabber is pinned to the glass's top edge
                // (not the content's), riding the morph and sharing the content's blur.
                ZStack {
                    if showsGrabber {
                        Capsule()
                            .fill(.white.opacity(0.3))
                            .frame(width: SurfaceMetrics.grabberSize.width, height: SurfaceMetrics.grabberSize.height)
                            .padding(.top, SurfaceMetrics.grabberInset)
                            .transition(SurfaceSwapTransition())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .animation(SurfaceMotion.content, value: showsGrabber)
                .allowsHitTesting(false)
            }
            // Timed blur pulse that restarts with every morph, independent of the springs,
            // so settling or overshoot can never bring the blur back.
            .keyframeAnimator(initialValue: CGFloat(0), trigger: morphCount) { view, blur in
                view.blur(radius: blur)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(morphPeak, duration: SurfaceMotion.morphBlurRise)
                    CubicKeyframe(0, duration: SurfaceMotion.morphBlurFall)
                }
            }
        }
        .scaleEffect(scrollScale)
        .offset(scrollOffset)
        .blur(radius: isPresented ? 0 : 12)
        .opacity(isPresented ? 1 : 0)
        .scaleEffect(isPresented ? 1 : 0.86, anchor: .bottom)
        .animation(SurfaceMotion.materialize, value: isPresented)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { surface?.glassFrame = $0 }
        .padding(SurfaceMetrics.overshootMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .environment(\.colorScheme, .dark)
        .environment(\.appearsActive, true)
        .materialActiveAppearance(.active)
        .onChange(of: id, initial: true) {
            currentID = id
            surface?.onScroll = { handleScroll($0) }
            // Content revived mid-transition may not report a new size, so fall back to its
            // last known one. Deferred so a fresh measurement from this update lands first.
            Task {
                guard currentID == id, let size = naturalSizes[id] else { return }
                spill(to: size)
            }
        }
    }

    /// Every content view reports its size, including outgoing content still transitioning out.
    /// Only the current content drives the glass; the rest is remembered in case it comes back.
    private func measured(_ size: CGSize, for measuredID: AnyHashable) {
        naturalSizes[measuredID] = size
        guard measuredID == currentID else { return }
        spill(to: size)
    }

    // MARK: - Scroll to collapse / expand

    private func handleScroll(_ event: SurfaceScrollEvent) {
        switch event.phase {
        case .began:
            scrollTravel = .zero
            scrollCommitted = false
        case .changed:
            guard !scrollCommitted else { return }
            scrollTravel.width += event.delta.width
            scrollTravel.height += event.delta.height
            scrollOffset = CGSize(
                width: rubberBand(scrollTravel.width, limit: SurfaceGesture.followLimit),
                height: rubberBand(
                    scrollTravel.height,
                    limit: verticalAction(for: scrollTravel.height) == nil
                        ? SurfaceGesture.blockedFollowLimit
                        : SurfaceGesture.followLimit
                )
            )
            if abs(scrollTravel.height) >= SurfaceGesture.commitDistance,
               let action = verticalAction(for: scrollTravel.height) {
                scrollCommitted = true
                action()
                withAnimation(SurfaceMotion.bow) { scrollOffset = .zero }
            }
        case .ended:
            if !scrollCommitted {
                withAnimation(SurfaceMotion.release) { scrollOffset = .zero }
            }
            scrollTravel = .zero
            scrollCommitted = false
        }
    }

    /// Scrolling down collapses, scrolling up expands.
    private func verticalAction(for travel: CGFloat) -> (() -> Void)? {
        travel > 0 ? onCollapse : (travel < 0 ? onExpand : nil)
    }

    /// Follows `travel` closely at first, then resists, approaching `limit` asymptotically.
    private func rubberBand(_ travel: CGFloat, limit: CGFloat) -> CGFloat {
        let resisted = limit * (1 - 1 / (abs(travel) / limit * SurfaceGesture.followStiffness + 1))
        return travel < 0 ? -resisted : resisted
    }

    /// Width leads when growing wider; otherwise height leads. The other axis follows after `lag`.
    private func spill(to natural: CGSize) {
        let clamped = CGSize(
            width: min(max(natural.width, SurfaceMetrics.minSide), SurfaceMetrics.maxSize.width),
            height: min(max(natural.height, SurfaceMetrics.minSide), SurfaceMetrics.maxSize.height)
        )
        guard clamped != target else { return }
        // Bigger morphs blur more, up to the full peak.
        let travel = max(abs(clamped.width - target.width), abs(clamped.height - target.height))
        morphPeak = SurfaceMotion.morphBlur * min(travel / SurfaceMotion.morphBlurRange, 1)
        morphCount += 1
        target = clamped
        followTask?.cancel()

        let widthLeads = clamped.width > surfaceWidth
        if widthLeads {
            withAnimation(SurfaceMotion.spillLead) { surfaceWidth = clamped.width }
        } else {
            withAnimation(SurfaceMotion.drainLead) { surfaceHeight = clamped.height }
        }

        followTask = Task {
            try? await Task.sleep(for: .seconds(SurfaceMotion.lag))
            guard !Task.isCancelled else { return }
            if widthLeads {
                withAnimation(SurfaceMotion.spillFollow) { surfaceHeight = clamped.height }
            } else {
                withAnimation(SurfaceMotion.drainFollow) { surfaceWidth = clamped.width }
            }
        }
    }
}

/// Like `.blurReplace`, with a tunable blur radius.
private struct SurfaceSwapTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .blur(radius: phase.isIdentity ? 0 : SurfaceMotion.swapBlur)
            .opacity(phase.isIdentity ? 1 : 0)
            .scaleEffect(phase.isIdentity ? 1 : SurfaceMotion.swapScale)
    }
}

private struct SpillWidth<Content: View>: View, Animatable {
    var width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: () -> Content
    var animatableData: CGFloat { get { width } set { width = newValue } }
    var body: some View { SpillHeight(width: width, height: height, content: content) }
}

private struct SpillHeight<Content: View>: View, Animatable {
    let width: CGFloat
    var height: CGFloat
    @ViewBuilder let content: () -> Content
    var animatableData: CGFloat { get { height } set { height = newValue } }

    private var squeeze: CGFloat {
        let shortest = min(width, height)
        guard shortest < SurfaceMetrics.minSide else { return 1 }
        return max(shortest / SurfaceMetrics.minSide, SurfaceMotion.minimumSqueeze)
    }
    private var w: CGFloat { max(width, SurfaceMetrics.minSide) * squeeze }
    private var h: CGFloat { max(height, SurfaceMetrics.minSide) * squeeze }
    // capsule while short, rounded rect once taller than minSide
    private var radius: CGFloat { min(min(w, h) / 2, SurfaceMetrics.maxCornerRadius) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content()
            .frame(width: w, height: h)
            .clipShape(shape)
            .background {
                shape.fill(SurfaceShade.gradient)
                    .padding(0.5)
                    .background { GlassSurface(radius: radius) }
            }
    }
}
