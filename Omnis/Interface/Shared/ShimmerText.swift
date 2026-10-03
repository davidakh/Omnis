import SwiftUI

/// Muted text with a soft light sweeping across it, for "working on it" states.
///
/// Each status stays up for a moment before the next replaces it, so one that would only flash
/// by ("Thinking" → "Looking at the screen" → "Thinking") is skipped instead of flickering.
struct ShimmerText: View {
    let text: String
    init(_ text: String) { self.text = text }

    @State private var shown: String?
    @State private var shownAt = Date.distantPast

    private static var minimumDuration: Double { 0.9 }

    var body: some View {
        let current = shown ?? text
        // Old and new status overlap while one blurs into the other.
        ZStack(alignment: .leading) {
            shimmer(current)
                .id(current)
                .transition(.blurReplace)
        }
        .task(id: text) {
            guard let shown else {
                self.shown = text
                shownAt = .now
                return
            }
            guard shown != text else { return }
            // A newer status cancels this wait, so only the latest one is ever shown.
            let wait = Self.minimumDuration - Date.now.timeIntervalSince(shownAt)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            withAnimation(SurfaceMotion.content) { self.shown = text }
            shownAt = .now
        }
    }

    private func shimmer(_ text: String) -> some View {
        TimelineView(.animation) { context in
            // The highlight sweeps from just off the leading edge to just off the trailing edge.
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            let center = UnitPoint(x: -0.3 + phase * 1.6, y: 0.5)
            Text(text)
                .foregroundStyle(.white.opacity(0.3))
                .overlay {
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.55), .clear],
                        startPoint: UnitPoint(x: center.x - 0.25, y: 0.5),
                        endPoint: UnitPoint(x: center.x + 0.25, y: 0.5)
                    )
                    .mask(Text(text))
                }
        }
    }
}
