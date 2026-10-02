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
}

/// Morphing glass container. Measures its content and springs the glass to fit it:
/// a capsule while short, a rounded rectangle once taller.
struct SurfaceHost<Content: View>: View {
    let id: AnyHashable
    @ViewBuilder let content: () -> Content

    @Environment(SurfaceState.self) private var surface: SurfaceState?

    @State private var surfaceWidth = SurfaceMetrics.minSide
    @State private var surfaceHeight = SurfaceMetrics.minSide
    @State private var target = CGSize(width: SurfaceMetrics.minSide, height: SurfaceMetrics.minSide)
    @State private var followTask: Task<Void, Never>?

    init(id: AnyHashable, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.content = content
    }

    private var isPresented: Bool { surface?.isPresented ?? true }

    var body: some View {
        SpillWidth(width: surfaceWidth, height: surfaceHeight, target: target) {
            ZStack {
                content()
                    .fixedSize()
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { spill(to: $0) }
                    .id(id)
                    .transition(.blurReplace)
            }
            .animation(SurfaceMotion.content, value: id)
        }
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
    }

    /// Width leads when growing wider; otherwise height leads. The other axis follows after `lag`.
    private func spill(to natural: CGSize) {
        let clamped = CGSize(
            width: min(max(natural.width, SurfaceMetrics.minSide), SurfaceMetrics.maxSize.width),
            height: min(max(natural.height, SurfaceMetrics.minSide), SurfaceMetrics.maxSize.height)
        )
        guard clamped != target else { return }
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

private struct SpillWidth<Content: View>: View, Animatable {
    var width: CGFloat
    let height: CGFloat
    let target: CGSize
    @ViewBuilder let content: () -> Content
    var animatableData: CGFloat { get { width } set { width = newValue } }
    var body: some View { SpillHeight(width: width, height: height, target: target, content: content) }
}

private struct SpillHeight<Content: View>: View, Animatable {
    let width: CGFloat
    var height: CGFloat
    let target: CGSize
    @ViewBuilder let content: () -> Content
    var animatableData: CGFloat { get { height } set { height = newValue } }

    private var morphBlur: CGFloat {
        let remaining = max(abs(width - target.width), abs(height - target.height))
        return SurfaceMotion.morphBlur * min(remaining / SurfaceMotion.morphBlurRange, 0.25)
    }
    private var squeeze: CGFloat {
        let shortest = min(width, height)
        guard shortest < SurfaceMetrics.minSide else { return 1 }
        return max(shortest / SurfaceMetrics.minSide, SurfaceMotion.minimumSqueeze)
    }
    private var w: CGFloat { max(width, SurfaceMetrics.minSide) * squeeze }
    private var h: CGFloat { min(max(height, SurfaceMetrics.minSide) * squeeze, w) }
    // capsule while short, rounded rect once taller than minSide
    private var radius: CGFloat { min(min(w, h) / 2, SurfaceMetrics.maxCornerRadius) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content()
            .blur(radius: morphBlur)
            .frame(width: w, height: h)
            .clipShape(shape)
            .background {
                shape.fill(SurfaceShade.gradient)
                    .padding(0.5)
                    .background { GlassSurface(radius: radius) }
            }
    }
}
