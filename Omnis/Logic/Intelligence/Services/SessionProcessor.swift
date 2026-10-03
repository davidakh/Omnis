import Foundation
import FoundationModels

/// What the model writes for a finished session.
@Generable
struct SessionDigest {
    @Guide(description: "A specific two- or three-word title naming the main topic, like \"Pricing Page Redesign\"")
    var title: String
    @Guide(description: "Two to four short paragraphs covering the topics, decisions and next steps")
    var summary: String
}

/// A short name for a chat, from its first question and answer.
@Generable
struct ChatTitle {
    @Guide(description: "A specific two- or three-word title naming the topic, like \"Swift Concurrency\"")
    var title: String
}

/// Notes already written for the start of a session while it was recording.
struct LiveNotes {
    var notes: [String] = []
    /// How many transcript lines (from the start) the notes cover.
    var coveredLines = 0
}

/// Writes each finished session's title and summary, then indexes it.
///
/// Reading a long transcript is what takes the time (an hour of talk is about 20k tokens,
/// several times the on-device window), so the work is spread out: while a session records,
/// each stretch of about 6k tokens is turned into short notes in the background. When it ends,
/// only the stretch since the last notes is left to read before the final summary, so it
/// arrives in seconds whatever the session's length. Sessions finished without live notes
/// (e.g. after a quit) are read in parts the same way.
@Observable
final class SessionProcessor {
    /// What's happening for sessions being summarized ("Summarizing part 2 of 3"), by id.
    private(set) var progress: [UUID: String] = [:]

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let index: SessionIndex
    @ObservationIgnored private let resolver: ModelResolver
    @ObservationIgnored private var inFlight: Set<UUID> = []

    @ObservationIgnored private var live = LiveNotes()
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    /// Most notes a part may produce; short notes keep each call quick and the combined notes
    /// small enough for the final summary.
    private static let noteTokens = 350
    /// Roughly 6k tokens of transcript: about 25 minutes of talk, and well inside the window
    /// once the instructions and notes are added.
    private static let livePartCharacters = 25_000

    init(store: SessionStore, index: SessionIndex, resolver: ModelResolver) {
        self.store = store
        self.index = index
        self.resolver = resolver
    }

    /// Picks up sessions that ended without finishing, e.g. after a quit.
    func processPending() async {
        for session in store.unprocessedSessions() {
            await process(session)
        }
    }

    func process(_ session: Session, liveNotes: LiveNotes? = nil) async {
        guard !inFlight.contains(session.id) else { return }
        inFlight.insert(session.id)
        defer {
            inFlight.remove(session.id)
            progress[session.id] = nil
        }

        let lines = session.orderedLines
        let covered = min(liveNotes?.coveredLines ?? 0, lines.count)
        let remaining = lines.dropFirst(covered).map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        let notes = liveNotes?.notes ?? []

        if !lines.isEmpty, let digest = await digest(transcript: remaining, notes: notes, sessionID: session.id) {
            if !session.hasCustomTitle, let title = Self.shortTitle(digest.title) {
                session.title = title
            }
            session.summary = digest.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            session.isProcessed = true
        }
        // Index even without a summary, so the transcript is searchable right away; a later
        // `processPending` adds the summary and re-indexes.
        store.save()
        index.index(session)
    }

    // MARK: - Live notes

    /// Starts collecting notes for a new recording.
    func liveSessionStarted() {
        liveTask?.cancel()
        liveTask = nil
        live = LiveNotes()
    }

    /// Called as the live transcript grows: once enough new talk has built up since the last
    /// notes, writes notes for it in the background.
    func liveTranscriptChanged(_ lines: [LiveLine]) {
        guard liveTask == nil, lines.count > live.coveredLines else { return }
        let pending = lines[live.coveredLines...].map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        guard pending.count >= Self.livePartCharacters, let model = try? resolver.onDevice() else { return }
        let upTo = lines.count
        liveTask = Task { [weak self] in
            guard let self else { return }
            if let notes = try? await self.notes(for: pending, model: model) {
                self.live.notes.append(notes)
                self.live.coveredLines = upTo
            }
            self.liveTask = nil
        }
    }

    /// Ends the recording's notes, waiting for any in progress, and hands them over.
    func finishLiveNotes() async -> LiveNotes {
        await liveTask?.value
        liveTask = nil
        defer { live = LiveNotes() }
        return live
    }

    // MARK: - Chat titles

    /// Names a new chat after its first exchange. Titles are short, so the on-device model is
    /// used directly: it's fast and always available.
    func titleChat(_ id: UUID, question: String, answer: String) async {
        guard let model = try? resolver.onDevice() else { return }
        let session = LanguageModelSession(
            model: model.model,
            instructions: "You name conversations with short, specific titles."
        )
        let prompt = "Title this conversation.\n\nQuestion: \(question.prefix(600))\nAnswer: \(answer.prefix(900))"
        guard let response = try? await session.respond(to: prompt, generating: ChatTitle.self),
              let title = Self.shortTitle(response.content.title) else { return }
        store.setGeneratedTitle(title, for: id)
    }

    /// Cleans a generated title and keeps it to at most three words: models occasionally run
    /// long or wrap the title in quotes.
    static func shortTitle(_ raw: String) -> String? {
        let words = raw
            .replacingOccurrences(of: "Title:", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(.init(charactersIn: "&+-'"))) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.prefix(3).joined(separator: " ")
    }

    // MARK: - Summarizing

    private func digest(transcript: String, notes: [String], sessionID: UUID) async -> SessionDigest? {
        let model: ResolvedModel
        if let chosen = try? await resolver.resolve() {
            model = chosen
        } else if let onDevice = try? resolver.onDevice() {
            model = onDevice
        } else {
            return nil
        }
        do {
            return try await digest(transcript: transcript, notes: notes, model: model, sessionID: sessionID)
        } catch where model.provider != .appleOnDevice {
            // Prefer a summary from the on-device model over none at all.
            guard let fallback = try? resolver.onDevice() else { return nil }
            return try? await digest(transcript: transcript, notes: notes, model: fallback, sessionID: sessionID)
        } catch {
            return nil
        }
    }

    private func digest(transcript: String, notes: [String], model: ResolvedModel, sessionID: UUID) async throws -> SessionDigest {
        let limit = Int(Double(model.promptBudget) * 0.85)
        var material: String
        var isNotes: Bool

        if notes.isEmpty, try await tokens(transcript, model) <= limit {
            // Short enough to summarize directly.
            material = transcript
            isNotes = false
        } else {
            var allNotes = notes
            if !transcript.isEmpty {
                allNotes += try await notes(forLongText: transcript, model: model, sessionID: sessionID)
            }
            material = allNotes.joined(separator: "\n")
            isNotes = true
            // Very long sessions: condense the notes themselves until they fit.
            while try await tokens(material, model) > limit {
                let condensed = try await notes(forLongText: material, model: model, sessionID: sessionID).joined(separator: "\n")
                guard condensed.count < material.count else { break }
                material = condensed
            }
        }

        progress[sessionID] = String(localized: "Writing the summary")
        let prompt = """
        Write a title and a summary for this recorded session.

        \(isNotes ? "Notes from the session" : "Transcript"):
        \(material)
        """
        let session = LanguageModelSession(
            model: model.model,
            instructions: """
            You summarize recorded meetings and conversations accurately and concisely. Lines \
            labeled "You" are the user; refer to them as "you".
            """
        )

        if model.supportsGuidedGeneration {
            return try await session.respond(to: prompt, generating: SessionDigest.self).content
        }
        let reply = try await session.respond(
            to: prompt + "\n\nReply with only the title on the first line, a blank line, then the summary."
        ).content
        var lines = reply.components(separatedBy: "\n")
        let title = lines.isEmpty ? "" : lines.removeFirst()
        return SessionDigest(
            title: title.replacingOccurrences(of: "Title:", with: "").trimmingCharacters(in: .whitespaces),
            summary: lines.joined(separator: "\n")
        )
    }

    /// Notes for text of any length: split into parts that fill the window, each turned into
    /// short notes. A part that fails is skipped rather than losing the whole summary.
    private func notes(forLongText text: String, model: ResolvedModel, sessionID: UUID) async throws -> [String] {
        let parts = try await split(text, model: model)
        var notes: [String] = []
        for (number, part) in parts.enumerated() {
            try Task.checkCancellation()
            if parts.count > 1 {
                progress[sessionID] = String(localized: "Summarizing part \(number + 1) of \(parts.count)")
            }
            if let note = try? await self.notes(for: part, model: model) { notes.append(note) }
        }
        guard !notes.isEmpty else { throw LanguageModelError.timeout(.init(debugDescription: "No part could be summarized")) }
        return notes
    }

    /// Short notes for one part. If it turns out too long for the window after all, it's
    /// halved and each half noted.
    private func notes(for part: String, model: ResolvedModel) async throws -> String {
        let session = LanguageModelSession(
            model: model.model,
            instructions: "You take concise notes on parts of meeting transcripts."
        )
        let options = GenerationOptions(maximumResponseTokens: Self.noteTokens)
        do {
            return try await session.respond(
                to: "List up to 8 key points, decisions and action items in this part, as short bullets:\n\n\(part)",
                options: options
            ).content
        } catch LanguageModelError.contextSizeExceeded {
            let lines = part.components(separatedBy: "\n")
            guard lines.count > 1 else { throw LanguageModelError.contextSizeExceeded(.init(contextSize: 0, tokenCount: 0, debugDescription: "A single line is too long")) }
            let middle = lines.count / 2
            let first = try await notes(for: lines[..<middle].joined(separator: "\n"), model: model)
            let second = try await notes(for: lines[middle...].joined(separator: "\n"), model: model)
            return first + "\n" + second
        }
    }

    /// Splits on line boundaries into parts that each fill most of the window, sized from the
    /// text's real tokens-per-character (estimates alone made parts less than half full).
    private func split(_ text: String, model: ResolvedModel) async throws -> [String] {
        let totalTokens = max(try await tokens(text, model), 1)
        let charactersPerToken = Double(text.count) / Double(totalTokens)
        let partTokens = model.promptBudget - Self.noteTokens - 200
        let maxCharacters = max(1_000, Int(Double(partTokens) * charactersPerToken))

        var parts: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count + 1 > maxCharacters, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Exact on device; estimated for other models.
    private func tokens(_ text: String, _ model: ResolvedModel) async throws -> Int {
        if model.isOnDevice { return try await SystemLanguageModel.default.tokenCount(for: text) }
        return model.estimatedTokens(text)
    }
}
