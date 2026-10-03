import Foundation

/// One line of the live transcript, before the session is saved.
struct LiveLine: Identifiable, Hashable {
    let id = UUID()
    let speaker: String
    let text: String
    /// Seconds from the start of the session.
    let offset: TimeInterval

    var timestamp: String {
        let seconds = Int(offset)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The session being recorded right now: its start time, pause state and transcript so far.
///
/// Audio capture and speech-to-text aren't wired up yet, so while recording this replays a
/// scripted meeting one line at a time. Everything downstream (live transcript, asking about
/// the session, saving, summarizing, indexing) already works on whatever lines arrive here,
/// so the real transcriber only has to call `append(speaker:text:)`.
@Observable
final class LiveRecorder {
    private(set) var startedAt: Date?
    private(set) var lines: [LiveLine] = []
    private(set) var isPaused = false

    var isRecording: Bool { startedAt != nil }

    private var feedTask: Task<Void, Never>?

    func start() {
        startedAt = .now
        lines = []
        isPaused = false
        startPlaceholderFeed()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    /// Ends recording and hands back what was captured.
    func stop() -> (startedAt: Date, lines: [LiveLine])? {
        feedTask?.cancel()
        feedTask = nil
        defer {
            startedAt = nil
            lines = []
            isPaused = false
        }
        guard let startedAt else { return nil }
        return (startedAt, lines)
    }

    func append(speaker: String, text: String) {
        guard let startedAt, !isPaused else { return }
        lines.append(LiveLine(speaker: speaker, text: text, offset: Date.now.timeIntervalSince(startedAt)))
    }

    // MARK: - Placeholder transcription

    private func startPlaceholderFeed() {
        feedTask?.cancel()
        feedTask = Task { [weak self] in
            var index = 0
            while !Task.isCancelled, index < Self.script.count {
                try? await Task.sleep(for: .seconds(2.5))
                guard let self, !Task.isCancelled else { return }
                guard !self.isPaused else { continue }
                let line = Self.script[index]
                self.append(speaker: line.speaker, text: line.text)
                index += 1
            }
        }
    }

    private static let script: [(speaker: String, text: String)] = [
        ("Maya", "Okay, let's get started. Thanks for joining, everyone."),
        ("Maya", "The main thing today is the pricing page redesign."),
        ("Sam", "The new layout is ready. We're testing two versions of the plan comparison table."),
        ("Maya", "When will we have results?"),
        ("Sam", "The experiment needs about two weeks of traffic, so around the 30th."),
        ("Priya", "Engineering can ship the winning version within a day of the results."),
        ("Maya", "Great. Let's also make sure the annual discount is clearly shown."),
        ("Sam", "I'll add it to both versions today."),
        ("Priya", "I'll set up the dashboard so we can watch conversion daily."),
        ("Maya", "Perfect. Let's check in again next Wednesday.")
    ]
}
