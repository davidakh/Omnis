import Foundation

/// One line of the live transcript, before the session is saved.
struct LiveLine: Identifiable, Hashable {
    var id = UUID()
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
/// `LiveTranscriber` feeds it: finished sentences through `append(speaker:text:duration:)`,
/// and words still being spoken through `setPartial(speaker:text:)`. Everything downstream
/// (live transcript, asking about the session, saving, summarizing, indexing) reads from here.
@Observable
final class LiveRecorder {
    private(set) var startedAt: Date?
    /// Finished lines, in spoken order.
    private(set) var lines: [LiveLine] = []
    /// What each speaker is saying right now, still being recognized.
    private(set) var partials: [LiveLine] = []
    private(set) var isPaused = false
    /// Shown in place of the transcript while there's nothing yet ("Downloading speech model").
    var status: String?
    /// A lasting note about the recording ("Recording your mic only…").
    var notice: String?

    var isRecording: Bool { startedAt != nil }

    /// Finished lines followed by the ones still in progress: what has been said so far.
    var transcriptSoFar: [LiveLine] { lines + partials }

    func start() {
        startedAt = .now
        lines = []
        partials = []
        isPaused = false
        status = nil
        notice = nil
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    /// Ends recording and hands back what was captured, including words still in progress.
    func stop() -> (startedAt: Date, lines: [LiveLine])? {
        defer {
            startedAt = nil
            lines = []
            partials = []
            isPaused = false
            status = nil
            notice = nil
        }
        guard let startedAt else { return nil }
        return (startedAt, (lines + partials).sorted { $0.offset < $1.offset })
    }

    /// Adds a finished line. `duration` is how long it took to say, so the line is stamped with
    /// when it started rather than when recognition finished.
    func append(speaker: String, text: String, duration: TimeInterval = 0) {
        guard let startedAt else { return }
        let offset = max(0, Date.now.timeIntervalSince(startedAt) - duration)
        let line = LiveLine(speaker: speaker, text: text, offset: offset)
        // The two audio streams finish lines independently; keep the transcript in spoken order.
        let index = lines.lastIndex { $0.offset <= offset }.map { $0 + 1 } ?? 0
        lines.insert(line, at: index)
        partials.removeAll { $0.speaker == speaker }
    }

    /// Updates (or clears, with empty text) what `speaker` is saying right now. The line keeps
    /// its identity while it grows, so the transcript doesn't flicker.
    func setPartial(speaker: String, text: String) {
        guard let startedAt else { return }
        guard !text.isEmpty else {
            partials.removeAll { $0.speaker == speaker }
            return
        }
        if let index = partials.firstIndex(where: { $0.speaker == speaker }) {
            let existing = partials[index]
            partials[index] = LiveLine(id: existing.id, speaker: speaker, text: text, offset: existing.offset)
        } else {
            partials.append(LiveLine(speaker: speaker, text: text, offset: Date.now.timeIntervalSince(startedAt)))
        }
    }
}
