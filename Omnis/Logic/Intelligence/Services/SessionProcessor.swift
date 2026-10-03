import Foundation
import FoundationModels
import OSLog

/// What the model writes for a finished session.
@Generable
struct SessionDigest {
    @Guide(description: "A specific two- or three-word title naming the main topic, like \"Pricing Page Redesign\"")
    var title: String
    @Guide(description: "Two to four short paragraphs covering the recording from start to finish: the main topics and key points in order. Decisions or next steps only if someone stated them.")
    var summary: String
}

/// The summary alone, streamed as structured output so the model writes only the summary
/// (as free text it sometimes started another "You: …" transcript line at the end).
@Generable
struct SummaryText {
    @Guide(description: "Two to four short paragraphs covering the recording from start to finish: the main topics and key points in order. Decisions or next steps only if someone stated them.")
    var summary: String
}

/// Where a session moves between topics, as read by the on-device model.
@Generable
struct SectionPlan {
    @Guide(description: "The parts of the session in order, each starting where the conversation moves to a new topic", .maximumCount(8))
    var sections: [PlannedSection]
}

@Generable
struct PlannedSection {
    @Guide(description: "Two to five words naming this part")
    var title: String
    @Guide(description: "When this part starts, copied exactly from a timestamp in the timeline, like 4:20")
    var start: String
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
    /// What's happening for sessions being summarized ("Summarizing Part 2 of 3"), by id.
    private(set) var progress: [UUID: String] = [:]
    /// The summary as it's being written, by id, so it can be read before it's finished.
    private(set) var drafts: [UUID: String] = [:]

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let index: SessionIndex
    @ObservationIgnored private let resolver: ModelResolver
    @ObservationIgnored private var inFlight: Set<UUID> = []

    @ObservationIgnored private var live = LiveNotes()
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    /// Most notes a part may produce; short notes keep each call quick and the combined notes
    /// small enough for the final summary.
    private static let noteTokens = 350
    /// Roughly 2k tokens of transcript, about 8 to 10 minutes of talk. Small stretches keep
    /// what's left to read when the session ends short, so the summary arrives in seconds.
    private static let livePartCharacters = 8_000

    /// Recordings are anything: meetings, calls, videos, podcasts, lectures. The prompts never
    /// assume a meeting, or a small model fills in decisions and action items that weren't there.
    private static let summaryInstructions = """
        You summarize recordings accurately and concisely: meetings, calls, videos, podcasts or \
        lectures. Describe only what was actually said; never add decisions, action items or \
        conclusions that aren't in it. Skip ads, sponsor messages and unrelated interruptions. \
        The transcript comes from speech recognition and may mishear names; use the correct \
        spelling only when it's clear from context. Lines labeled "You" are the user; refer to \
        them as "you".
        """

    private static let notesInstructions = """
        You take concise, faithful notes on parts of recording transcripts (meetings, calls, \
        videos, podcasts or lectures). Note only what was said. Skip ads, sponsor messages and \
        unrelated interruptions.
        """

    init(store: SessionStore, index: SessionIndex, resolver: ModelResolver) {
        self.store = store
        self.index = index
        self.resolver = resolver
    }

    /// Picks up sessions that ended without finishing, e.g. after a quit, and gives sessions
    /// summarized before sections existed their sections.
    func processPending() async {
        for session in store.unprocessedSessions() {
            await process(session)
        }
        for session in store.sessions where session.isProcessed && session.sections.isEmpty && !inFlight.contains(session.id) {
            let lines = session.orderedLines
            guard let last = lines.last, last.offset >= Self.minimumSectionedLength else { continue }
            session.sections = await sections(for: lines)
            store.save()
        }
    }

    func process(_ session: Session, liveNotes: LiveNotes? = nil) async {
        guard !inFlight.contains(session.id) else { return }
        inFlight.insert(session.id)
        defer {
            inFlight.remove(session.id)
            progress[session.id] = nil
            drafts[session.id] = nil
        }

        let lines = session.orderedLines
        let covered = min(liveNotes?.coveredLines ?? 0, lines.count)
        let remaining = lines.dropFirst(covered).map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
        let notes = liveNotes?.notes ?? []

        let speakers = Set(lines.map(\.speaker))
        if !lines.isEmpty, let digest = await digest(transcript: remaining, notes: notes, speakers: speakers, sessionID: session.id) {
            if !session.hasCustomTitle, let title = Self.shortTitle(digest.title) {
                session.title = title
            }
            session.summary = digest.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            session.isProcessed = true
            store.save()
            // Points of interest come after the summary, which is already readable meanwhile.
            session.sections = await sections(for: lines)
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

    /// Starts loading the model as a recording stops, so it's ready by the time the
    /// transcript is saved and the summary begins.
    func prepareForSummary() {
        guard let model = try? resolver.onDevice() else { return }
        LanguageModelSession(model: model.model, instructions: Self.summaryInstructions).prewarm()
    }

    /// Ends the recording's notes, waiting for any in progress, and hands them over.
    func finishLiveNotes() async -> LiveNotes {
        await liveTask?.value
        liveTask = nil
        defer { live = LiveNotes() }
        return live
    }

    // MARK: - Sections

    /// Sessions shorter than this are one topic; they get no sections.
    private static let minimumSectionedLength: TimeInterval = 120

    /// Splits the session into titled parts by topic, from a timestamped outline of the
    /// transcript (thinned evenly when long, so it fits the window).
    private func sections(for lines: [TranscriptLine]) async -> [SessionSection] {
        guard let last = lines.last, last.offset >= Self.minimumSectionedLength, lines.count >= 6,
              let model = try? resolver.onDevice() else { return [] }

        let outline = lines.map { "[\(SessionSection.format($0.offset))] \($0.speaker): \($0.text.prefix(100))" }
        let maxCharacters = Int(Double(model.promptBudget) * 0.6 * model.charactersPerToken)
        let total = outline.reduce(0) { $0 + $1.count + 1 }
        let step = max(1, Int((Double(total) / Double(maxCharacters)).rounded(.up)))
        let timeline = stride(from: 0, to: outline.count, by: step).map { outline[$0] }.joined(separator: "\n")

        let session = LanguageModelSession(
            model: model.model,
            instructions: "You divide recordings into sections by topic, like chapters. Ads and sponsor messages aren't topics; leave them out."
        )
        let prompt = "Divide this session into 3 to 8 sections by topic.\n\nTimeline:\n\(timeline)"
        let options = GenerationOptions(samplingMode: .greedy)
        guard let plan = try? await session.respond(to: prompt, generating: SectionPlan.self, options: options).content else {
            return []
        }

        // Keep sections with readable times inside the session, in order, at least 20 s apart.
        var sections: [SessionSection] = []
        for planned in plan.sections {
            guard let start = Self.seconds(from: planned.start), start <= last.offset else { continue }
            let title = planned.title.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !title.isEmpty else { continue }
            sections.append(SessionSection(title: title, start: start))
        }
        sections.sort { $0.start < $1.start }
        sections = sections.reduce(into: []) { kept, section in
            if let previous = kept.last, section.start - previous.start < 20 { return }
            kept.append(section)
        }
        guard sections.count >= 2 else { return [] }
        sections[0].start = 0  // the first section covers the opening
        return sections
    }

    /// "4:20" or "1:04:20" → seconds.
    private static func seconds(from timestamp: String) -> TimeInterval? {
        let parts = timestamp.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ":").compactMap { Double($0) }
        guard (2...3).contains(parts.count) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
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

    private func digest(transcript: String, notes: [String], speakers: Set<String>, sessionID: UUID) async -> SessionDigest? {
        let model: ResolvedModel
        if let chosen = try? await resolver.resolve() {
            model = chosen
        } else if let onDevice = try? resolver.onDevice() {
            model = onDevice
        } else {
            return nil
        }
        // The model occasionally fails a request outright and succeeds on the next, so one
        // failure gets a retry before falling back (rather than leaving the summary unwritten
        // until the next launch).
        for attempt in 1...2 {
            do {
                return try await digest(transcript: transcript, notes: notes, speakers: speakers, model: model, sessionID: sessionID)
            } catch is CancellationError {
                return nil
            } catch {
                Self.log.error("Summary attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                if attempt == 1 { try? await Task.sleep(for: .seconds(1)) }
            }
        }
        // Prefer a summary from the on-device model over none at all.
        guard model.provider != .appleOnDevice, let fallback = try? resolver.onDevice() else { return nil }
        return try? await digest(transcript: transcript, notes: notes, speakers: speakers, model: fallback, sessionID: sessionID)
    }

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Omnis", category: "Summaries")

    private func digest(transcript: String, notes: [String], speakers: Set<String>, model: ResolvedModel, sessionID: UUID) async throws -> SessionDigest {
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
                allNotes += try await self.notes(forLongText: transcript, model: model, sessionID: sessionID)
            }
            material = allNotes.joined(separator: "\n")
            isNotes = true
            // Very long sessions: condense the notes themselves until they fit.
            while try await tokens(material, model) > limit {
                let condensed = try await self.notes(forLongText: material, model: model, sessionID: sessionID).joined(separator: "\n")
                guard condensed.count < material.count else { break }
                material = condensed
            }
        }

        progress[sessionID] = String(localized: "Writing the Summary")
        let prompt = """
        Summarize this recording in two to four short paragraphs, covering it from start to \
        finish: what it was, then the main topics and points in the order they came up. Mention \
        decisions or next steps only if they were stated.

        \(isNotes ? "Notes from the session" : "Transcript"):
        \(material)
        """
        // Streamed, so the summary can be read while it's written.
        let session = LanguageModelSession(model: model.model, instructions: Self.summaryInstructions)
        var summary = ""
        if model.supportsGuidedGeneration {
            for try await snapshot in session.streamResponse(to: prompt, generating: SummaryText.self) {
                guard let text = snapshot.content.summary else { continue }
                summary = text
                drafts[sessionID] = text
            }
        } else {
            for try await snapshot in session.streamResponse(to: prompt) {
                summary = snapshot.content
                drafts[sessionID] = summary
            }
        }
        summary = Self.trimmingTrailingSpeaker(summary, speakers: speakers)
        // The title comes from the finished summary: a short read, so it takes a moment.
        let title = (try? await self.title(forSummary: summary, model: model)) ?? ""
        return SessionDigest(title: title, summary: summary)
    }

    /// Removes a speaker label the model left dangling at the end ("…next steps. You"), in case
    /// it slips through.
    static func trimmingTrailingSpeaker(_ text: String, speakers: Set<String>) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = speakers.map { $0.lowercased() }
        while true {
            let lowered = result.lowercased()
            guard let label = labels.first(where: { lowered.hasSuffix($0) || lowered.hasSuffix($0 + ":") }) else { break }
            let length = lowered.hasSuffix(label + ":") ? label.count + 1 : label.count
            let before = result.dropLast(length)
            // Only a whole word standing after the end of a sentence or on its own line.
            guard let previous = before.last, previous == "\n" || previous == " ",
                  [".", "!", "?", "\n"].contains(before.trimmingCharacters(in: .whitespaces).last.map(String.init) ?? "\n") else { break }
            result = String(before).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private func title(forSummary summary: String, model: ResolvedModel) async throws -> String {
        let prompt = "Title this session.\n\n\(summary.prefix(900))"
        let session = LanguageModelSession(model: model.model, instructions: "You name recordings (meetings, calls, videos, podcasts) with short, specific titles.")
        if model.supportsGuidedGeneration {
            return try await session.respond(to: prompt, generating: ChatTitle.self).content.title
        }
        return try await session.respond(to: prompt + "\nReply with only the title.").content
    }

    /// Notes for text of any length: split into parts that fill the window, each turned into
    /// short notes. A part that fails is skipped rather than losing the whole summary.
    private func notes(forLongText text: String, model: ResolvedModel, sessionID: UUID) async throws -> [String] {
        let parts = try await split(text, model: model)
        var notes: [String] = []
        for (number, part) in parts.enumerated() {
            try Task.checkCancellation()
            if parts.count > 1 {
                progress[sessionID] = String(localized: "Summarizing Part \(number + 1) of \(parts.count)")
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
            instructions: Self.notesInstructions
        )
        let options = GenerationOptions(maximumResponseTokens: Self.noteTokens)
        do {
            return try await session.respond(
                to: "List up to 8 key points from this part, in order, as short bullets. Include decisions or action items only if someone actually stated them.\n\n\(part)",
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
