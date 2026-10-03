import SwiftUI

/// Generated text that streams in: each new piece fades up out of a blur as it arrives.
///
/// Text already there when the view appears is shown as is unless `revealsInitialText`, so
/// reopened answers don't replay.
struct StreamingText: View {
    let text: AttributedString
    var revealsInitialText = false

    /// When each piece of the text arrived: the character offset it ends at, and the time.
    private struct Arrival: Equatable {
        var end: Int
        var date: Date
    }

    @State private var arrivals: [Arrival] = []
    @State private var isRevealing = false

    private static var duration: Double { 0.45 }

    init(_ text: AttributedString, revealsInitialText: Bool = false) {
        self.text = text
        self.revealsInitialText = revealsInitialText
    }

    init(_ text: String, revealsInitialText: Bool = false) {
        self.init(AttributedString(text), revealsInitialText: revealsInitialText)
    }

    var body: some View {
        TimelineView(.animation(paused: !isRevealing)) { context in
            // Once nothing is mid-reveal, draw everything settled rather than at the last frame.
            composed.textRenderer(BlurRevealRenderer(now: isRevealing ? context.date : .distantFuture, duration: Self.duration))
        }
        .onAppear {
            arrivals = [Arrival(end: count, date: revealsInitialText ? .now : .distantPast)]
            if revealsInitialText { isRevealing = true }
        }
        .onChange(of: text) { arrived() }
        // Stops the timeline shortly after the latest piece has fully appeared.
        .task(id: arrivals.last?.date) {
            guard isRevealing else { return }
            try? await Task.sleep(for: .seconds(Self.duration + 0.05))
            if !Task.isCancelled { isRevealing = false }
        }
    }

    private var count: Int { text.characters.count }

    private func arrived() {
        let now = Date.now
        let settled = arrivals.last { now.timeIntervalSince($0.date) >= Self.duration }?.end ?? 0
        guard count > (arrivals.last?.end ?? 0) else {
            // Rewritten shorter: nothing new to reveal.
            arrivals = [Arrival(end: count, date: .distantPast)]
            return
        }
        // Fold pieces that have finished appearing into one, so the text stays a few runs.
        var next = arrivals.filter { $0.end > settled && now.timeIntervalSince($0.date) < Self.duration }
        next.insert(Arrival(end: settled, date: .distantPast), at: 0)
        next.append(Arrival(end: count, date: now))
        arrivals = next
        isRevealing = true
    }

    /// The text cut at each arrival, every piece tagged with when it arrived.
    private var composed: Text {
        var pieces: [Text] = []
        var start = 0
        let characters = text.characters
        for arrival in arrivals + [Arrival(end: count, date: .distantPast)] {
            let end = min(arrival.end, count)
            guard end > start else { continue }
            let lower = characters.index(characters.startIndex, offsetBy: start)
            let upper = characters.index(characters.startIndex, offsetBy: end)
            pieces.append(Text(AttributedString(text[lower..<upper])).customAttribute(ArrivalTime(date: arrival.date)))
            start = end
        }
        return pieces.reduce(Text(verbatim: "")) { Text("\($0)\($1)") }
    }
}

/// When a run of streamed text arrived.
private struct ArrivalTime: TextAttribute {
    let date: Date
}

/// Draws each run blurred and faded by how recently it arrived.
private struct BlurRevealRenderer: TextRenderer {
    let now: Date
    let duration: Double

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                let progress = run[ArrivalTime.self].map { min(max(now.timeIntervalSince($0.date) / duration, 0), 1) } ?? 1
                guard progress < 1 else {
                    context.draw(run)
                    continue
                }
                var copy = context
                copy.opacity = progress
                copy.addFilter(.blur(radius: (1 - progress) * 6))
                copy.draw(run)
            }
        }
    }
}
