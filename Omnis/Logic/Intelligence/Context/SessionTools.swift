import Foundation
import FoundationModels

/// How sessions are introduced to the model: a numbered line each, newest first, with what the
/// session is, so it can tell them apart and answer "what was it about" without reading more.
enum SessionCatalog {
    static func line(_ number: Int, _ session: Session) -> String {
        let date = session.createdAt.formatted(date: .abbreviated, time: .shortened)
        let minutes = max(1, Int(session.length / 60))
        let about = session.definition ?? firstSentence(of: session.summary) ?? String(localized: "(not summarized yet)")
        return "\(number). \"\(session.title)\", \(date), \(minutes) min: \(about)"
    }

    private static func firstSentence(of text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        let end = text.firstIndex { ".!?".contains($0) }.map { text.index(after: $0) } ?? text.endIndex
        return String(text[..<end].prefix(200))
    }
}

/// Finds lines in transcripts by plain text: no model involved, so it takes milliseconds.
/// Lines are scored by how many of the query's words they contain (the whole phrase counts
/// most), and each hit comes back with a few lines around it so the model sees the exchange.
enum TranscriptSearch {
    struct Excerpt {
        let session: String
        let lines: [TranscriptLine]
        let score: Double
    }

    /// Lines either side of a hit.
    static let padding = 2

    static func excerpts(in sessions: [Session], matching query: String, limit: Int) -> [Excerpt] {
        let phrase = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = Self.terms(in: query)
        guard !terms.isEmpty else { return [] }

        var excerpts: [Excerpt] = []
        for session in sessions {
            let lines = session.orderedLines
            var hits: [(index: Int, score: Double)] = []
            for (index, line) in lines.enumerated() {
                let words = Self.terms(in: "\(line.speaker) \(line.text)")
                // Prefix matching, so "guest" also finds "guests".
                let shared = terms.filter { term in words.contains { $0.hasPrefix(term) } }.count
                guard shared > 0 else { continue }
                var score = Double(shared) / Double(terms.count)
                if phrase.count > 3, line.text.lowercased().contains(phrase) { score += 1 }
                hits.append((index, score))
            }
            // Windows around the best lines; overlapping windows merge into one excerpt.
            var windows: [(range: ClosedRange<Int>, score: Double)] = []
            for hit in hits.sorted(by: { $0.score > $1.score }).prefix(limit) {
                let window = max(0, hit.index - padding)...min(lines.count - 1, hit.index + padding)
                if let overlap = windows.firstIndex(where: { $0.range.overlaps(window) }) {
                    let merged = windows[overlap].range
                    windows[overlap].range = min(merged.lowerBound, window.lowerBound)...max(merged.upperBound, window.upperBound)
                } else {
                    windows.append((window, hit.score))
                }
            }
            excerpts += windows.map { Excerpt(session: session.title, lines: Array(lines[$0.range]), score: $0.score) }
        }
        return Array(excerpts.sorted { $0.score > $1.score }.prefix(limit))
    }

    static func format(_ excerpt: Excerpt) -> String {
        "From \"\(excerpt.session)\":\n" + excerpt.lines.map { "[\($0.timestamp)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// Lowercased words worth matching: three letters or more, or numbers, minus filler.
    static func terms(in text: String) -> [String] {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var seen = Set<String>()
        return words.filter { word in
            (word.count >= 3 || word.allSatisfy(\.isNumber)) && !stopWords.contains(word) && seen.insert(word).inserted
        }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "what", "who", "whom", "when", "where", "why",
        "how", "did", "does", "that", "this", "with", "from", "about", "into", "they", "them",
        "their", "there", "then", "than", "have", "has", "had", "you", "your", "our", "but", "not",
        "any", "all", "can", "could", "would", "should", "will", "just", "say", "said", "tell",
        "session", "sessions", "meeting", "call", "recording", "latest", "last", "recent"
    ]
}

/// Caps lookups per answer so the model can't keep searching for minutes: past the limit,
/// the tools tell it to answer with what it has.
nonisolated final class LookupBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var used = 0
    let limit: Int

    init(limit: Int) { self.limit = limit }

    /// Whether another lookup is allowed (and counts it).
    func spend() -> Bool {
        lock.withLock {
            guard used < limit else { return false }
            used += 1
            return true
        }
    }

    static let exhausted = "No more lookups are allowed. Answer now from what you have found; if it isn't enough, say what you couldn't find."
}

/// Finds a session the model names, by its title or its number in the list.
enum SessionLookup {
    static func session(_ reference: String, in sessions: [Session]) -> Session? {
        let text = reference.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"“”#.")))
        if let number = Int(text), sessions.indices.contains(number - 1) { return sessions[number - 1] }
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return nil }
        return sessions.first { $0.title.lowercased() == lowered }
            ?? sessions.first { $0.title.lowercased().contains(lowered) || lowered.contains($0.title.lowercased()) }
    }
}

/// Searches transcripts by keywords and returns a few short excerpts with context.
nonisolated struct SearchTranscriptTool: Tool {
    /// The sessions in the list the model was given, newest first.
    let sessions: @MainActor @Sendable () -> [Session]
    let budget: LookupBudget
    let onUse: @Sendable (String) -> Void

    let name = "searchTranscript"
    let description = """
        Finds what was said in a session by keywords, without reading the whole transcript. \
        Returns a few short excerpts with times and speakers. Use words likely to have been said \
        (names, topics, "guest", "welcome", "introduce"), not a question.
        """

    @Generable
    struct Arguments {
        @Guide(description: "The session's title or number from the list, or \"all\" to search every listed session")
        var session: String
        @Guide(description: "Two to five keywords to find, like \"guest welcome name\"")
        var keywords: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard budget.spend() else { return LookupBudget.exhausted }
        return await MainActor.run {
            let listed = sessions()
            let reference = arguments.session.trimmingCharacters(in: .whitespacesAndNewlines)
            let targets: [Session]
            if reference.isEmpty || reference.lowercased() == "all" {
                targets = listed
                onUse(String(localized: "Searching your sessions for “\(arguments.keywords)”"))
            } else if let session = SessionLookup.session(reference, in: listed) {
                targets = [session]
                onUse(String(localized: "Searching “\(session.title)” for “\(arguments.keywords)”"))
            } else {
                return "There's no session called \(reference) in the list."
            }
            let found = TranscriptSearch.excerpts(in: targets, matching: arguments.keywords, limit: 4)
            guard !found.isEmpty else {
                return "Nothing matches \"\(arguments.keywords)\". Try other words once, or answer from what you have."
            }
            return found.map(TranscriptSearch.format).joined(separator: "\n\n")
        }
    }
}

/// Reads one session's summary, for questions about what happened overall.
nonisolated struct ReadSummaryTool: Tool {
    let sessions: @MainActor @Sendable () -> [Session]
    let budget: LookupBudget
    let onUse: @Sendable (String) -> Void

    let name = "readSummary"
    let description = """
        Reads one session's summary: its main topics and points in order. Use it for overall \
        questions (what was discussed, key points); use searchTranscript for specific details.
        """

    @Generable
    struct Arguments {
        @Guide(description: "The session's title or number from the list")
        var session: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard budget.spend() else { return LookupBudget.exhausted }
        return await MainActor.run {
            guard let session = SessionLookup.session(arguments.session, in: sessions()) else {
                return "There's no session called \(arguments.session) in the list."
            }
            onUse(String(localized: "Reading the summary of “\(session.title)”"))
            return session.summary.map { "Summary of \"\(session.title)\":\n\($0)" }
                ?? "\"\(session.title)\" hasn't been summarized yet. Use searchTranscript instead."
        }
    }
}
