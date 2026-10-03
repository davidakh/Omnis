import SwiftUI

/// Muted text with a soft light sweeping across it, for "working on it" states.
struct ShimmerText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
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
