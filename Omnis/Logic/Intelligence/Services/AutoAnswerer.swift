import Foundation
import FoundationModels

/// A reply that's always written: for the first suggestion (the user just asked for one) and
/// for questions put to the user.
@Generable
struct SuggestedLine {
    @Guide(description: "What the user should say next, in their own voice: first person, natural, one to three short sentences, ready to say aloud")
    var reply: String
}

/// What the model writes when the others may or may not be waiting on the user.
@Generable
struct AutoReply {
    @Guide(description: "True only if the others are waiting on the user to answer or respond right now")
    var needsReply: Bool
    @Guide(description: "What the user should say next, in their own voice: first person, natural, one to three short sentences, ready to say aloud. Empty if no reply is needed.")
    var reply: String
}

/// Live help in a conversation: while a session records, watches the transcript and, each
/// time the other side finishes speaking and is waiting on the user, suggests what to say;
/// when the user asks a question themselves, answers it.
///
/// Started from a live ask like "what should I say next?"; runs until the stream is cancelled
/// (the stop button). Always uses the on-device model and only the last few minutes of talk,
/// so suggestions arrive within a second or two.
final class AutoAnswerer {
    enum Update {
        /// Waiting for the others to say something that needs an answer.
        case listening
        /// Writing a reply.
        case thinking
        /// A suggestion as it's written (`text` grows); `id` stays the same for one suggestion.
        case suggestion(id: UUID, replyingTo: String, text: String)
        /// The suggestion with `id` is complete.
        case finished(id: UUID)
        /// A suggestion was dropped because the others kept talking.
        case discarded(id: UUID)
        /// Something went wrong writing a reply; shown briefly, then it keeps listening.
        case note(String)
    }

    private let recorder: LiveRecorder
    private let resolver: ModelResolver
    /// The user's past sessions, so questions about them are answered from what was said.
    private let index: SessionIndex

    /// How long the others must be quiet before a reply is worth writing.
    private static let quietTime: Duration = .milliseconds(700)
    /// About the last few minutes of talk: enough context, short enough to read in a moment.
    private static let contextCharacters = 4_000

    private static let instructions = """
        You help the user during a live conversation. When the others are waiting on the user, \
        write exactly what the user should say next, in their voice: natural, specific, first \
        person, one to three short sentences, ready to say aloud. When the user asks a question \
        themselves, answer it directly and concisely so they can use the answer right away. \
        Use only the conversation and the past sessions given to you; general knowledge like \
        math or definitions is fine. Never make up meetings, people, dates, numbers or facts. If \
        the user asks about something you weren't given, say you couldn't find it in their \
        sessions. If the others ask for facts you don't have, suggest an honest reply, like \
        offering to check and follow up. No preamble and no quotation marks.
        """

    init(recorder: LiveRecorder, resolver: ModelResolver, index: SessionIndex) {
        self.recorder = recorder
        self.resolver = resolver
        self.index = index
    }

    /// A past-session passage must match at least this well to be offered as context.
    private static let pastSessionScore = 0.35

    /// Passages from past sessions that match what's being asked, as prompt context.
    private func pastSessions(for text: String) -> String? {
        let hits = index.search(text, limit: 3, perSession: 1).filter { $0.score >= Self.pastSessionScore }
        guard !hits.isEmpty else { return nil }
        return hits.map { hit in
            "\(hit.sessionTitle), \(hit.date.formatted(date: .abbreviated, time: .omitted)):\n\(hit.text.prefix(500))"
        }.joined(separator: "\n\n")
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

    // MARK: - Who's speaking

    /// Whether a line is someone other than the user. Mic-only, every line is labeled "You"
    /// whoever spoke it, so any line counts.
    private func isOthers(_ line: LiveLine) -> Bool {
        !recorder.separatesSpeakers || line.speaker != LiveTranscriber.you
    }

    private var othersAreTalking: Bool {
        recorder.partials.contains(where: isOthers)
    }

    /// The user asked a question themselves (only knowable when speakers are told apart).
    private func isUsersQuestion(_ line: LiveLine) -> Bool {
        recorder.separatesSpeakers && line.speaker == LiveTranscriber.you && Self.isQuestion(line.text)
    }

    /// A line worth responding to: the others speaking, or the user asking something.
    private func needsAttention(_ line: LiveLine) -> Bool {
        isOthers(line) || isUsersQuestion(line)
    }

    static func isQuestion(_ text: String) -> Bool {
        let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lowered.contains("?") { return true }
        let openers = ["what", "why", "how", "when", "where", "who", "which", "can ", "could ",
                       "should ", "is ", "are ", "do ", "does ", "did ", "will ", "would ", "tell me"]
        return openers.contains { lowered.hasPrefix($0) }
    }

    // MARK: - Loop

    private func run(_ continuation: AsyncStream<Update>.Continuation) async {
        guard let model = try? resolver.onDevice() else {
            continuation.yield(.note(String(localized: "Apple Intelligence isn't available for auto answer.")))
            continuation.finish()
            return
        }
        LanguageModelSession(model: model.model, instructions: Self.instructions).prewarm()

        // Asked "what should I say next?", so answer right away, whatever was said last.
        var answeredThrough = recorder.lines.count
        if !recorder.lines.isEmpty {
            answeredThrough = await suggest(model: model, always: true, into: continuation) ?? answeredThrough
        }

        while !Task.isCancelled {
            continuation.yield(.listening)
            guard await waitForTheirTurn(after: answeredThrough) else { break }
            answeredThrough = await suggest(model: model, always: false, into: continuation) ?? answeredThrough
        }
        continuation.finish()
    }

    /// Waits until the others have said something new and gone quiet. False if cancelled.
    private func waitForTheirTurn(after count: Int) async -> Bool {
        var quietSince: ContinuousClock.Instant?
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
            let lines = recorder.lines
            let newToAnswer = lines.count > count && lines.last.map(needsAttention) == true
            // Wait until nobody is mid-sentence (someone may still be finishing the point).
            guard newToAnswer, recorder.partials.isEmpty, !recorder.isPaused else {
                quietSince = nil
                continue
            }
            let now = ContinuousClock.now
            if let quietSince, now - quietSince >= Self.quietTime { return true }
            if quietSince == nil { quietSince = now }
        }
        return false
    }

    /// Writes one suggestion for the conversation as it stands. `always` skips the model's
    /// check of whether a reply is needed (the user just asked for one, or they were asked a
    /// question). If the others pick back up before it's done, it's dropped. Returns the
    /// transcript length it covered, or nil if it was dropped.
    private func suggest(model: ResolvedModel, always: Bool, into continuation: AsyncStream<Update>.Continuation) async -> Int? {
        let lines = recorder.lines
        guard !lines.isEmpty else { return nil }
        let count = lines.count
        let latest = lines.last(where: needsAttention)
        let replyingTo = latest?.text ?? ""
        let userAsked = latest.map(isUsersQuestion) == true
        let mustReply = always || userAsked || Self.isQuestion(replyingTo)

        var transcript: [String] = []
        var length = 0
        for line in lines.reversed() {
            let text = "\(line.speaker): \(line.text)"
            guard length + text.count <= Self.contextCharacters else { break }
            transcript.insert(text, at: 0)
            length += text.count
        }
        let speakers = recorder.separatesSpeakers
            ? "Lines labeled \"You\" are the user; the others are everyone else."
            : "Everything was picked up by one microphone, so every line is labeled \"You\" even when someone else spoke. Work out from context who is talking and what the user is being asked."
        // Anything from past sessions about what's being asked; otherwise say there's nothing,
        // so a question about an old meeting isn't answered by guessing.
        let past = pastSessions(for: replyingTo).map { "From the user's past sessions:\n\($0)" }
            ?? "Nothing in the user's past sessions matches this."
        let prompt = """
            \(speakers)

            \(past)

            The conversation so far (most recent last):
            \(transcript.joined(separator: "\n"))

            \(userAsked
                ? "The user just asked a question. Answer it directly and concisely."
                : "What should the user say next? If the latest line is the user asking a question, answer it directly instead.")
            """

        continuation.yield(.thinking)
        let id = UUID()
        let session = LanguageModelSession(model: model.model, instructions: Self.instructions)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 160)
        var wrote = false

        /// Someone picked back up: drop this one and wait for the full point.
        func interrupted() -> Bool {
            (userAsked ? !recorder.partials.isEmpty : othersAreTalking) || recorder.lines.count > count
        }
        func show(_ reply: String?) {
            guard let reply, !reply.isEmpty else { return }
            wrote = true
            continuation.yield(.suggestion(id: id, replyingTo: replyingTo, text: reply))
        }

        do {
            if mustReply {
                for try await snapshot in session.streamResponse(to: prompt, generating: SuggestedLine.self, options: options) {
                    try Task.checkCancellation()
                    if !always, interrupted() { break }
                    show(snapshot.content.reply)
                }
            } else {
                for try await snapshot in session.streamResponse(to: prompt, generating: AutoReply.self, options: options) {
                    try Task.checkCancellation()
                    if interrupted() { break }
                    if snapshot.content.needsReply == false { return count }
                    show(snapshot.content.reply)
                }
            }
        } catch is CancellationError {
            if wrote { continuation.yield(.discarded(id: id)) }
            return nil
        } catch {
            if wrote { continuation.yield(.discarded(id: id)) }
            continuation.yield(.note(String(localized: "Couldn't suggest a reply to that.")))
            return count  // don't retry the same moment
        }

        if !always, interrupted() {
            if wrote { continuation.yield(.discarded(id: id)) }
            return nil
        }
        if wrote { continuation.yield(.finished(id: id)) }
        return count
    }
}
