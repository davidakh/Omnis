import Foundation
import FoundationModels

/// What the model writes when asked for the user's next line.
@Generable
struct AutoReply {
    @Guide(description: "True only if the others are waiting on the user to answer or respond right now")
    var needsReply: Bool
    @Guide(description: "What the user should say next, in their own voice: first person, natural, one to three short sentences, ready to say aloud. Empty if no reply is needed.")
    var reply: String
}

/// Live help in a conversation: while a session records, watches the transcript and, each
/// time the other side finishes speaking and is waiting on the user, suggests what to say.
///
/// Started from a live ask like "what should I say next?"; runs until the stream is cancelled
/// (the stop button). Always uses the on-device model and only the last few minutes of talk,
/// so suggestions arrive within a second or two.
final class AutoAnswerer {
    enum Update {
        /// Waiting for the others to say something that needs an answer.
        case listening
        /// A suggestion as it's written (`text` grows); `id` stays the same for one suggestion.
        case suggestion(id: UUID, replyingTo: String, text: String)
        /// The suggestion with `id` is complete.
        case finished(id: UUID)
        /// A suggestion was dropped because the others kept talking.
        case discarded(id: UUID)
    }

    private let recorder: LiveRecorder
    private let resolver: ModelResolver

    /// How long the others must be quiet before a reply is worth writing.
    private static let quietTime: Duration = .milliseconds(700)
    /// About the last few minutes of talk: enough context, short enough to read in a moment.
    private static let contextCharacters = 4_000

    private static let instructions = """
        You help the user during a live conversation. Lines labeled "You" are the user; the \
        others are everyone else. When the others are waiting on the user, write exactly what \
        the user should say next, in their voice: natural, specific, first person, one to three \
        short sentences, ready to say aloud. No preamble and no quotation marks.
        """

    init(recorder: LiveRecorder, resolver: ModelResolver) {
        self.recorder = recorder
        self.resolver = resolver
    }

    /// Phrases that ask for help answering, which start auto mode.
    static func isRequest(_ question: String) -> Bool {
        let text = question.lowercased()
        return [
            "what should i say", "what do i say", "what should i answer", "what do i answer",
            "what should i respond", "how should i respond", "how should i answer", "how do i respond",
            "how do i answer", "help me answer", "help me respond", "help me reply", "answer for me",
            "respond for me", "reply for me", "what should i reply", "what do i reply", "say next",
            "auto answer", "autoanswer", "auto-answer"
        ].contains(where: text.contains)
    }

    func updates() -> AsyncStream<Update> {
        AsyncStream { continuation in
            let task = Task { await run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Loop

    private func run(_ continuation: AsyncStream<Update>.Continuation) async {
        guard let model = try? resolver.onDevice() else {
            continuation.finish()
            return
        }
        LanguageModelSession(model: model.model, instructions: Self.instructions).prewarm()

        // Asked "what should I say next?", so answer what's pending right away.
        var answeredThrough = recorder.lines.count
        if recorder.lines.contains(where: { $0.speaker != LiveTranscriber.you }) {
            answeredThrough = await suggest(model: model, into: continuation) ?? answeredThrough
        }

        while !Task.isCancelled {
            continuation.yield(.listening)
            guard await waitForTheirTurn(after: answeredThrough) else { break }
            answeredThrough = await suggest(model: model, into: continuation) ?? answeredThrough
        }
        continuation.finish()
    }

    /// Waits until the others have said something new and gone quiet. False if cancelled.
    private func waitForTheirTurn(after count: Int) async -> Bool {
        var quietSince: ContinuousClock.Instant?
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
            let lines = recorder.lines
            let theyAreTalking = recorder.partials.contains { $0.speaker != LiveTranscriber.you }
            let newFromThem = lines.count > count && lines.last?.speaker != LiveTranscriber.you
            guard newFromThem, !theyAreTalking, !recorder.isPaused else {
                quietSince = nil
                continue
            }
            let now = ContinuousClock.now
            if let quietSince, now - quietSince >= Self.quietTime { return true }
            if quietSince == nil { quietSince = now }
        }
        return false
    }

    /// Writes one suggestion for the conversation as it stands. If the others start talking
    /// again before it's done, it's dropped (the next one will have their full point).
    /// Returns the transcript length it answered, or nil if it was dropped or not needed.
    private func suggest(model: ResolvedModel, into continuation: AsyncStream<Update>.Continuation) async -> Int? {
        let lines = recorder.lines
        guard !lines.isEmpty else { return nil }
        let count = lines.count
        let replyingTo = lines.last { $0.speaker != LiveTranscriber.you }?.text ?? ""

        var transcript: [String] = []
        var length = 0
        for line in lines.reversed() {
            let text = "\(line.speaker): \(line.text)"
            guard length + text.count <= Self.contextCharacters else { break }
            transcript.insert(text, at: 0)
            length += text.count
        }
        let prompt = """
            The conversation so far (most recent last):
            \(transcript.joined(separator: "\n"))

            What should the user say next?
            """

        let id = UUID()
        let session = LanguageModelSession(model: model.model, instructions: Self.instructions)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 160)
        var wrote = false
        do {
            for try await snapshot in session.streamResponse(to: prompt, generating: AutoReply.self, options: options) {
                try Task.checkCancellation()
                // The others picked back up: drop this one and wait for their full point.
                if recorder.partials.contains(where: { $0.speaker != LiveTranscriber.you }) || recorder.lines.count > count {
                    if wrote { continuation.yield(.discarded(id: id)) }
                    return nil
                }
                if snapshot.content.needsReply == false { return count }
                guard let reply = snapshot.content.reply, !reply.isEmpty else { continue }
                wrote = true
                continuation.yield(.suggestion(id: id, replyingTo: replyingTo, text: reply))
            }
        } catch {
            if wrote { continuation.yield(.discarded(id: id)) }
            return nil
        }
        if wrote { continuation.yield(.finished(id: id)) }
        return count
    }
}
