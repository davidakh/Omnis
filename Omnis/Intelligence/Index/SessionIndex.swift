import Foundation
import SwiftData

/// A passage from a past session that matched a question.
struct SearchHit: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let sessionTitle: String
    let date: Date
    let source: IndexChunk.Source
    let text: String
    let startOffset: TimeInterval?
    let score: Double
}

/// Makes every saved session findable by the model. Each session's summary and transcript are
/// split into short passages, embedded on device and stored as `IndexChunk`s; a search blends
/// semantic similarity with keyword overlap, title matches and time phrases ("yesterday",
/// "my last meeting").
final class SessionIndex {
    private let store: SessionStore
    private let embedder = TextEmbedder()
    /// Everything needed to score chunks, loaded once and rebuilt after changes.
    private var cache: [Entry]?

    /// Target passage length. Long enough to carry context, short enough to embed well and to
    /// pack several into the on-device model's small window.
    private static let chunkCharacters = 600

    init(store: SessionStore) {
        self.store = store
    }

    // MARK: - Indexing

    /// (Re)builds the passages for one session.
    func index(_ session: Session) {
        guard session.kind == .session else { return }
        for chunk in session.chunks { store.context.delete(chunk) }

        for passage in passages(for: session) {
            // The title rides along in the embedding so "the Roy call" finds Roy's session.
            guard let embedding = embedder.embed("\(session.title). \(passage.text)") else { continue }
            let chunk = IndexChunk(
                source: passage.source,
                text: passage.text,
                startOffset: passage.offset,
                language: embedding.language,
                vector: embedding.vector
            )
            chunk.session = session
            store.context.insert(chunk)
        }
        store.save()
        cache = nil
    }

    /// Call after deleting or renaming sessions so searches see the change.
    func invalidate() {
        cache = nil
    }

    private struct Passage {
        let source: IndexChunk.Source
        let text: String
        let offset: TimeInterval?
    }

    private func passages(for session: Session) -> [Passage] {
        var result: [Passage] = []

        if let summary = session.summary, !summary.isEmpty {
            let paragraphs = summary.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            for group in Self.group(paragraphs) {
                result.append(Passage(source: .summary, text: group.joined(separator: "\n"), offset: nil))
            }
        }

        // Transcript windows overlap by one line so an exchange is never split from its context.
        let lines = session.orderedLines
        var window: [TranscriptLine] = []
        var length = 0
        for line in lines {
            let text = "\(line.speaker): \(line.text)"
            if length + text.count > Self.chunkCharacters, !window.isEmpty {
                result.append(transcriptPassage(window))
                window = window.suffix(1)
                length = window.reduce(0) { $0 + $1.text.count + $1.speaker.count + 2 }
            }
            window.append(line)
            length += text.count
        }
        if !window.isEmpty { result.append(transcriptPassage(window)) }
        return result
    }

    private func transcriptPassage(_ lines: [TranscriptLine]) -> Passage {
        Passage(
            source: .transcript,
            text: lines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n"),
            offset: lines.first?.offset
        )
    }

    private static func group(_ paragraphs: [String]) -> [[String]] {
        var groups: [[String]] = []
        var current: [String] = []
        var length = 0
        for paragraph in paragraphs {
            if length + paragraph.count > chunkCharacters, !current.isEmpty {
                groups.append(current)
                current = []
                length = 0
            }
            current.append(paragraph)
            length += paragraph.count
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    // MARK: - Search

    private struct Entry {
        let sessionID: UUID
        let title: String
        let titleTerms: Set<String>
        let date: Date
        let source: IndexChunk.Source
        let text: String
        let terms: Set<String>
        let offset: TimeInterval?
        let language: String
        let vector: [Float]
    }

    private func entries() -> [Entry] {
        if let cache { return cache }
        let built = store.sessions.flatMap { session in
            let titleTerms = Self.terms(in: session.title)
            return session.chunks.map { chunk in
                Entry(
                    sessionID: session.id,
                    title: session.title,
                    titleTerms: titleTerms,
                    date: session.createdAt,
                    source: chunk.source,
                    text: chunk.text,
                    terms: Self.terms(in: chunk.text),
                    offset: chunk.startOffset,
                    language: chunk.language,
                    vector: chunk.vector
                )
            }
        }
        cache = built
        return built
    }

    /// The best passages for `query`, at most `perSession` from any one session so a single
    /// long meeting can't crowd out the rest.
    func search(_ query: String, limit: Int = 8, perSession: Int = 3, excluding excluded: Set<UUID> = []) -> [SearchHit] {
        let candidates = entries().filter { !excluded.contains($0.sessionID) }
        guard !candidates.isEmpty else { return [] }

        let queryEmbedding = embedder.embed(query)
        let queryTerms = Self.terms(in: query)
        let timeBoosts = timeIntent(in: query, candidates: candidates)

        let scored: [(entry: Entry, score: Double)] = candidates.map { entry in
            var semantic = 0.0
            if let queryEmbedding, queryEmbedding.language == entry.language {
                semantic = max(0, TextEmbedder.cosine(queryEmbedding.vector, entry.vector))
            }
            var keyword = 0.0
            var titleMatch = 0.0
            if !queryTerms.isEmpty {
                keyword = Double(queryTerms.intersection(entry.terms).count) / Double(queryTerms.count)
                titleMatch = Double(queryTerms.intersection(entry.titleTerms).count) / Double(queryTerms.count)
            }
            var score = 0.6 * semantic + 0.4 * keyword + 0.3 * titleMatch
            score += timeBoosts[entry.sessionID] ?? 0
            if entry.source == .summary { score += 0.05 }
            return (entry, score)
        }

        var perSessionCount: [UUID: Int] = [:]
        var hits: [SearchHit] = []
        for (entry, score) in scored.sorted(by: { $0.score > $1.score }) {
            guard hits.count < limit else { break }
            // Weak matches only count when nothing better turned up.
            guard score >= 0.15 || hits.isEmpty else { break }
            let used = perSessionCount[entry.sessionID, default: 0]
            guard used < perSession else { continue }
            perSessionCount[entry.sessionID] = used + 1
            hits.append(SearchHit(
                sessionID: entry.sessionID,
                sessionTitle: entry.title,
                date: entry.date,
                source: entry.source,
                text: entry.text,
                startOffset: entry.offset,
                score: score
            ))
        }
        return hits
    }

    /// Boosts sessions that match time phrases in the question.
    private func timeIntent(in query: String, candidates: [Entry]) -> [UUID: Double] {
        let text = query.lowercased()
        let calendar = Calendar.current
        var dates: [UUID: Date] = [:]
        for entry in candidates { dates[entry.sessionID] = entry.date }
        var boosts: [UUID: Double] = [:]

        func boost(where matches: (Date) -> Bool) {
            for (id, date) in dates where matches(date) { boosts[id, default: 0] += 0.3 }
        }

        if text.contains("today") || text.contains("this morning") {
            boost { calendar.isDateInToday($0) }
        }
        if text.contains("yesterday") {
            boost { calendar.isDateInYesterday($0) }
        }
        if text.contains("this week") {
            boost { $0 > Date.now.addingTimeInterval(-7 * 86_400) }
        }
        if text.contains("last week") {
            boost { $0 <= Date.now.addingTimeInterval(-7 * 86_400) && $0 > Date.now.addingTimeInterval(-14 * 86_400) }
        }
        // "my last meeting", "the latest session", "most recent call"
        if ["last", "latest", "recent", "previous"].contains(where: text.contains) {
            let newest = dates.sorted { $0.value > $1.value }.prefix(2)
            for (rank, item) in newest.enumerated() {
                boosts[item.key, default: 0] += rank == 0 ? 0.3 : 0.15
            }
        }
        return boosts
    }

    // MARK: - Keywords

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "what", "when", "where", "who", "why", "how",
        "did", "does", "about", "with", "that", "this", "from", "have", "has", "had", "you",
        "your", "our", "they", "them", "their", "can", "could", "would", "should", "will",
        "there", "which", "into", "any", "all", "say", "said", "tell", "me", "my", "we", "us",
        "session", "sessions", "meeting", "meetings", "call", "last", "latest", "recent"
    ]

    static func terms(in text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(words.map(String.init).filter { $0.count >= 3 && !stopWords.contains($0) })
    }
}
