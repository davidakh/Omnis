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

    /// Set while the current content has a scroll view (see `surfaceScrollable()`). Gestures that
    /// start then go to the scroll view instead of driving collapse / expand.
    @ObservationIgnored var scrollableOwner: UUID?
    /// Whether the scrollable content is scrolled to its top.
    @ObservationIgnored var contentAtTop = true
    /// Called once the fingers have pulled far enough past the top of the scrollable content.
    @ObservationIgnored var onPullPastTop: (() -> Void)?
}

extension View {
    /// Marks a scroll view as the surface's scrollable content: it receives scroll gestures, and
    /// pulling down past its top (fingers still on the trackpad) collapses the surface.
    /// Pass `startsAtTop: false` for content that opens scrolled elsewhere (e.g. a transcript
    /// anchored at the bottom); the scroll position is only reported once it changes.
    func surfaceScrollable(startsAtTop: Bool = true) -> some View {
        modifier(SurfaceScrollableModifier(startsAtTop: startsAtTop))
    }
}

private struct SurfaceScrollableModifier: ViewModifier {
    let startsAtTop: Bool
    @Environment(SurfaceState.self) private var surface: SurfaceState?
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            // Always elastic, so even a short list can be pulled past its top.
            .scrollBounceBehavior(.always, axes: .vertical)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top <= 0.5
            } action: { _, atTop in
                surface?.contentAtTop = atTop
            }
            .onAppear {
                surface?.scrollableOwner = token
                surface?.contentAtTop = startsAtTop
            }
            .onDisappear {
                // Only clear our own claim; incoming content may already have registered.
                if surface?.scrollableOwner == token { surface?.scrollableOwner = nil }
            }
    }
}

/// A scroll gesture over the glass. `delta` is in points and follows the fingers
/// (SwiftUI axes: positive height = down), regardless of the natural-scrolling setting.
struct SurfaceScrollEvent {
    enum Phase { case began, changed, ended }

    var phase: Phase
    var delta: CGSize = .zero
    /// The vertical part belongs to scrollable content; only horizontal pulls apply to the surface.
    var horizontalOnly = false
}

/// Morphing glass container. Measures its content and springs the glass to fit it:
/// a capsule while short, a rounded rectangle once taller.
///
/// Scrolling over the glass makes it follow the scroll vector; scrolling far enough down
/// calls `onCollapse`, far enough up calls `onExpand`, pulling far enough to the right calls
/// `onBack`, and the glass bows back into place.
struct SurfaceHost<Content: View>: View {
    let id: AnyHashable
    var onCollapse: (() -> Void)?
    var onExpand: (() -> Void)?
    var onBack: (() -> Void)?
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
    @State private var idleReleaseTask: Task<Void, Never>?

    init(
        id: AnyHashable,
        onCollapse: (() -> Void)? = nil,
        onExpand: (() -> Void)? = nil,
        onBack: (() -> Void)? = nil,
        showsGrabber: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.id = id
        self.onCollapse = onCollapse
        self.onExpand = onExpand
        self.onBack = onBack
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
            // A box exactly the glass's size. The content hangs centred over it and the
            // grabber is pinned to its top, so neither follows the content's own (animating)
            // size; both share the blur pulse below.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    ZStack {
                        content()
                            .fixedSize()
                            .onGeometryChange(for: CGSize.self) { $0.size } action: { [id] in measured($0, for: id) }
                            .id(id)
                            .transition(SurfaceSwapTransition())
                    }
                    .animation(SurfaceMotion.content, value: id)
                }
                .overlay(alignment: .top) {
                    ZStack {
                        if showsGrabber {
                            Capsule()
                                .fill(.white.opacity(0.3))
                                .frame(width: SurfaceMetrics.grabberSize.width, height: SurfaceMetrics.grabberSize.height)
                                .padding(.top, SurfaceMetrics.grabberInset)
                                .transition(SurfaceSwapTransition())
                        }
                    }
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
            surface?.onPullPastTop = { onCollapse?() }
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
            // Cap single-event jumps (e.g. coarse mouse-wheel ticks) so the glass never lurches.
            let cap = SurfaceGesture.maxEventDelta
            scrollTravel.width += min(max(event.delta.width, -cap), cap)
            scrollTravel.height += min(max(event.delta.height, -cap), cap)
            scheduleIdleRelease()

            // Over scrollable content the glass only follows clearly sideways pulls,
            // so ordinary vertical scrolling doesn't nudge it.
            let sideways = abs(scrollTravel.width) > abs(scrollTravel.height)
            let followsX = !event.horizontalOnly || sideways
            let target = CGSize(
                width: followsX
                    ? rubberBand(
                        scrollTravel.width,
                        limit: sideAction(for: scrollTravel.width) == nil && onBack != nil
                            ? SurfaceGesture.blockedFollowLimit
                            : SurfaceGesture.followLimit
                    )
                    : 0,
                height: event.horizontalOnly
                    ? 0
                    : rubberBand(
                        scrollTravel.height,
                        limit: verticalAction(for: scrollTravel.height) == nil
                            ? SurfaceGesture.blockedFollowLimit
                            : SurfaceGesture.followLimit
                    )
            )
            // Ease toward the fingers on a damped spring, which smooths uneven event timing.
            withAnimation(SurfaceMotion.follow) { scrollOffset = target }

            if !event.horizontalOnly,
               abs(scrollTravel.height) >= SurfaceGesture.commitDistance,
               let action = verticalAction(for: scrollTravel.height) {
                commit(action)
            } else if scrollTravel.width >= SurfaceGesture.sideCommitDistance,
                      scrollTravel.width > abs(scrollTravel.height) * SurfaceGesture.sideDominance,
                      let action = sideAction(for: scrollTravel.width) {
                commit(action)
            }
        case .ended:
            idleReleaseTask?.cancel()
            if !scrollCommitted {
                withAnimation(SurfaceMotion.release) { scrollOffset = .zero }
            }
            scrollTravel = .zero
            scrollCommitted = false
        }
    }

    /// If scroll events stop arriving without an end (fingers resting, or a lost `ended`),
    /// level the glass back out instead of leaving it displaced.
    private func scheduleIdleRelease() {
        idleReleaseTask?.cancel()
        idleReleaseTask = Task {
            try? await Task.sleep(for: .seconds(SurfaceGesture.idleRelease))
            guard !Task.isCancelled, !scrollCommitted else { return }
            scrollTravel = .zero
            withAnimation(SurfaceMotion.release) { scrollOffset = .zero }
        }
    }

    private func commit(_ action: () -> Void) {
        scrollCommitted = true
        idleReleaseTask?.cancel()
        action()
        withAnimation(SurfaceMotion.bow) { scrollOffset = .zero }
    }

    /// Scrolling down collapses, scrolling up expands.
    private func verticalAction(for travel: CGFloat) -> (() -> Void)? {
        travel > 0 ? onCollapse : (travel < 0 ? onExpand : nil)
    }

    /// Pulling to the right goes back.
    private func sideAction(for travel: CGFloat) -> (() -> Void)? {
        travel > 0 ? onBack : nil
    }

    /// Follows `travel` gently at first, then levels out smoothly toward `limit` (tanh),
    /// so the glass never moves far and never stops abruptly.
    private func rubberBand(_ travel: CGFloat, limit: CGFloat) -> CGFloat {
        limit * tanh(travel / limit * SurfaceGesture.followStiffness)
    }

    /// Width leads when growing wider; otherwise height leads. The other axis follows after `lag`.
    private func spill(to natural: CGSize) {
        let clamped = CGSize(
            width: min(max(natural.width, SurfaceMetrics.minSide), SurfaceMetrics.maxSize.width),
            height: min(max(natural.height, SurfaceMetrics.minSide), SurfaceMetrics.maxSize.height)
        )
        guard clamped != target else { return }
        // Bigger morphs blur more, up to the full peak. Small ones (a line of streamed text,
        // say) skip the blur so steady growth doesn't flicker.
        let travel = max(abs(clamped.width - target.width), abs(clamped.height - target.height))
        if travel >= SurfaceMotion.morphBlurMinTravel {
            morphPeak = SurfaceMotion.morphBlur * min(travel / SurfaceMotion.morphBlurRange, 1)
            morphCount += 1
        }
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
        // The content hangs centred over a box exactly the glass's size, so its own size
        // (which animates during swaps) can never pull it off centre.
        Color.clear
            .frame(width: w, height: h)
            .overlay { content() }
            .clipShape(shape)
            .background {
                shape.fill(SurfaceShade.gradient)
                    .padding(0.5)
                    .background { GlassSurface(radius: radius) }
            }
    }
}
