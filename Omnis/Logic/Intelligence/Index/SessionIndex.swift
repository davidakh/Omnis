import Foundation
import FoundationModels
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

    /// Rebuilds sessions whose passages were embedded in another language, so every vector is
    /// comparable (earlier builds picked a language per passage).
    func reindexIfNeeded() {
        for session in store.sessions where session.chunks.contains(where: { $0.language != embedder.language }) {
            index(session)
        }
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

    /// The newest recorded sessions (not chats), newest first, so the model knows which
    /// sessions exist and when, not only the passages a search returned.
    func recentSessions(limit: Int) -> [Session] {
        Array(store.sessions.prefix(limit))
    }

    /// A recorded session by id, for reading it in full.
    func session(withID id: UUID) -> Session? {
        store.session(withID: id).flatMap { $0.kind == .session ? $0 : nil }
    }

    /// A recorded session by id or title (exact, then the newest whose title contains it).
    func session(matching reference: String) -> Session? {
        let text = reference.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"“”")))
        if let id = UUID(uuidString: text), let session = session(withID: id) { return session }
        let lowered = text.lowercased()
        return store.sessions.first { $0.title.lowercased() == lowered }
            ?? store.sessions.first { $0.title.lowercased().contains(lowered) }
    }

    /// The best passages for `query`, at most `perSession` from any one session so a single
    /// long meeting can't crowd out the rest.
    func search(_ query: String, limit: Int = 8, perSession: Int = 3, excluding excluded: Set<UUID> = []) -> [SearchHit] {
        let candidates = entries().filter { !excluded.contains($0.sessionID) }
        guard !candidates.isEmpty else { return [] }

        let queryEmbedding = embedder.embed(query)
        let queryTerms = Self.terms(in: query)
        let timeBoosts = timeIntent(in: query, dates: Dictionary(candidates.map { ($0.sessionID, $0.date) }) { first, _ in first })

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
    private func timeIntent(in query: String, dates: [UUID: Date]) -> [UUID: Double] {
        let text = query.lowercased()
        let calendar = Calendar.current
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
        // "my last meeting", "the latest session", "most recent call", but not "last week".
        let namesPeriod = ["last week", "last month", "this week", "yesterday", "today"].contains(where: text.contains)
        if !namesPeriod, ["last", "latest", "recent", "previous"].contains(where: text.contains) {
            let newest = dates.sorted { $0.value > $1.value }.prefix(2)
            for (rank, item) in newest.enumerated() {
                boosts[item.key, default: 0] += rank == 0 ? 0.3 : 0.15
            }
        }
        return boosts
    }

    // MARK: - Library filter

    /// Embeddings of each item's title and gist, keyed by id; `key` notices edits.
    private var itemEmbeddings: [UUID: (key: String, embedding: TextEmbedder.Embedding)] = [:]

    /// A score below this means the item doesn't match the filter.
    private static let filterThreshold = 0.25
    /// An instant match this strong stands even when the model didn't pick it.
    private static let strongMatch = 0.45

    /// Filters the Sessions or Chats list by a natural-language query ("pricing meetings last
    /// week", "the hiking club names"), best matches first. Sessions also match on anything
    /// said in them, through the passage index; chats match on their title and opening exchange.
    func filter(_ items: [Session], matching query: String) -> [Session] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return scoredMatches(items, matching: query).map(\.item)
    }

    /// The instant ranking with its scores, best first, above the threshold.
    private func scoredMatches(_ items: [Session], matching query: String) -> [(item: Session, score: Double)] {

        let queryEmbedding = embedder.embed(query)
        let queryTerms = Self.terms(in: query)
        let timeBoosts = timeIntent(in: query, dates: Dictionary(items.map { ($0.id, $0.createdAt) }) { first, _ in first })
        var passageScores: [UUID: Double] = [:]
        for hit in search(query, limit: 200, perSession: 1) {
            passageScores[hit.sessionID] = max(passageScores[hit.sessionID] ?? 0, hit.score)
        }

        let scored: [(item: Session, score: Double)] = items.map { item in
            let text = Self.gist(of: item)
            var semantic = 0.0
            if let queryEmbedding, let embedding = embedding(of: item, text: text),
               embedding.language == queryEmbedding.language {
                semantic = max(0, TextEmbedder.cosine(queryEmbedding.vector, embedding.vector))
            }
            var keyword = 0.0
            var titleMatch = 0.0
            if !queryTerms.isEmpty {
                keyword = Double(queryTerms.intersection(Self.terms(in: text)).count) / Double(queryTerms.count)
                titleMatch = Double(queryTerms.intersection(Self.terms(in: item.title)).count) / Double(queryTerms.count)
            }
            let match = max(0.55 * semantic + 0.25 * keyword + 0.3 * titleMatch, passageScores[item.id] ?? 0)
            // A query that's only a time ("last week") matches on the date alone.
            let base = queryTerms.isEmpty && timeBoosts[item.id] != nil ? Self.filterThreshold : match
            return (item, base + (timeBoosts[item.id] ?? 0))
        }
        return scored
            .filter { $0.score >= Self.filterThreshold }
            .sorted { $0.score > $1.score }
    }

    /// The on-device model's picks for a library search.
    @Generable
    struct LibraryMatches {
        @Guide(description: "The exact titles of the items that match the search, best match first. Empty if none match.")
        var titles: [String]
    }

    /// The on-device model's check of one item against a search.
    @Generable
    enum Relevance { case matches, unrelated }

    @Generable
    struct RelevanceCheck {
        @Guide(description: "matches: the item is genuinely about what's searched for. unrelated: it isn't.")
        var verdict: Relevance
    }

    /// The most items the model reads at once; beyond that, the instant ranking narrows them.
    private static let refineLimit = 40

    /// A second pass over the filter that matches by meaning ("travel plans" finds a Lisbon
    /// trip, "programming" a Swift chat), where the instant ranking only sees shared words and
    /// coarse embeddings. The chosen model picks items by title; picks the instant ranking
    /// also found go first, then the instant ranking's other matches, then the model's own
    /// picks after each passes a focused yes/no check (so a vague search can't invent one).
    /// Returns nil if the model isn't available, so the instant results stay.
    func refine(_ items: [Session], matching query: String, using model: (any LanguageModel)?) async -> [Session]? {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !items.isEmpty, let model else { return nil }

        let scored = scoredMatches(items, matching: query)
        let instant = scored.map(\.item)
        let instantIDs = Set(instant.map(\.id))
        let candidates = Array((instant + items.filter { !instantIDs.contains($0.id) }).prefix(Self.refineLimit))
        let passages = matchingPassages(for: query)
        let list = candidates.map { item in
            let date = item.createdAt.formatted(date: .abbreviated, time: .omitted)
            return "- \(description(of: item, date: date, passage: passages[item.id]))"
        }.joined(separator: "\n")

        let session = LanguageModelSession(model: model, instructions: """
            You find items in the user's library of recorded sessions and chats that match a \
            search. Match by meaning: topics, people, places and dates, not just exact words. \
            Only include items that genuinely match.
            """)
        let prompt = """
            Today is \(Date.now.formatted(date: .complete, time: .omitted)).
            Search: \(query)

            Items:
            \(list)
            """
        let options = GenerationOptions(samplingMode: .greedy)
        guard let response = try? await session.respond(to: prompt, generating: LibraryMatches.self, options: options) else {
            return nil
        }
        let picks = Self.items(titled: response.content.titles, in: candidates)

        let agreed = picks.filter { instantIDs.contains($0.id) }
        let agreedIDs = Set(agreed.map(\.id))
        var confirmed: [Session] = []
        for item in picks where !instantIDs.contains(item.id) {
            if await confirm(item, matches: query, passage: passages[item.id], using: model) { confirmed.append(item) }
        }
        // Once the model has found something that holds up, instant matches it passed over stay
        // only if strong; a single shared word ("plans") isn't enough to outrank what it found.
        let modelFound = !agreed.isEmpty || !confirmed.isEmpty
        let others = scored.filter { !agreedIDs.contains($0.item.id) && (!modelFound || $0.score >= Self.strongMatch) }
        return agreed + others.map(\.item) + confirmed
    }

    /// A focused yes/no on one item, for picks nothing else supports.
    private func confirm(_ item: Session, matches query: String, passage: String?, using model: any LanguageModel) async -> Bool {
        let session = LanguageModelSession(model: model, instructions: """
            Decide whether an item from the user's library matches their search. Say unrelated \
            unless the item is genuinely about what's searched for.
            """)
        let date = item.createdAt.formatted(date: .abbreviated, time: .omitted)
        let prompt = "Search: \(query)\nItem: \(description(of: item, date: date, passage: passage))"
        let options = GenerationOptions(samplingMode: .greedy)
        let response = try? await session.respond(to: prompt, generating: RelevanceCheck.self, options: options)
        return response?.content.verdict == .matches
    }

    /// For sessions, the transcript passage that best matches the search, since the detail it's
    /// looking for ("the train to Sintra") may only be in the transcript.
    private func matchingPassages(for query: String) -> [UUID: String] {
        var passages: [UUID: String] = [:]
        for hit in search(query, limit: 200, perSession: 1) where hit.score >= 0.2 && hit.source == .transcript {
            passages[hit.sessionID] = hit.text.replacingOccurrences(of: "\n", with: " ")
        }
        return passages
    }

    private func description(of item: Session, date: String, passage: String?) -> String {
        let about = Self.about(item).prefix(200).replacingOccurrences(of: "\n", with: " ")
        let transcript = passage.map { " Transcript: \($0.prefix(160))" } ?? ""
        return "\"\(item.title)\" (\(date)): \(about)\(transcript)"
    }

    /// Small models copy titles far more reliably than they count list positions. Each reply
    /// claims the first unclaimed item with that title: exact first, then a reply containing a
    /// title (longest first, so "Pricing Page Redesign" wins over "Pricing").
    private static func items(titled replies: [String], in candidates: [Session]) -> [Session] {
        var remaining = candidates
        var picked: [Session] = []
        for reply in replies {
            let wanted = reply.lowercased()
            let trimmed = wanted.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            let index = remaining.firstIndex { $0.title.lowercased() == trimmed }
                ?? remaining.indices
                    .filter { wanted.contains(remaining[$0].title.lowercased()) }
                    .max { remaining[$0].title.count < remaining[$1].title.count }
            guard let index else { continue }
            picked.append(remaining.remove(at: index))
        }
        return picked
    }

    /// What an item is about, for matching: its title plus its summary, or a chat's opening.
    private static func gist(of item: Session) -> String {
        "\(item.title). \(about(item).prefix(500))"
    }

    /// Its summary, or for a chat (or a session not yet summarized) its opening lines.
    private static func about(_ item: Session) -> String {
        item.summary ?? item.orderedLines.prefix(4).map(\.text).joined(separator: " ")
    }

    private func embedding(of item: Session, text: String) -> TextEmbedder.Embedding? {
        let key = "\(item.title)|\(item.summary?.count ?? 0)|\(item.lines.count)"
        if let cached = itemEmbeddings[item.id], cached.key == key { return cached.embedding }
        guard let embedding = embedder.embed(text) else { return nil }
        itemEmbeddings[item.id] = (key, embedding)
        return embedding
    }

    // MARK: - Keywords

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "what", "when", "where", "who", "why", "how",
        "did", "does", "about", "with", "that", "this", "from", "have", "has", "had", "you",
        "your", "our", "they", "them", "their", "can", "could", "would", "should", "will",
        "there", "which", "into", "any", "all", "say", "said", "tell", "me", "my", "we", "us",
        "session", "sessions", "meeting", "meetings", "call", "calls", "chat", "chats", "last",
        "latest", "recent", "week", "weeks", "month", "today", "yesterday", "morning",
        "something", "anything", "thing", "things", "stuff", "find", "show", "where", "whats"
    ]

    static func terms(in text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return Set(words.map(String.init).filter { $0.count >= 3 && !stopWords.contains($0) }.map(stem))
    }

    /// Folds simple plurals together ("trains" matches "train") without a full stemmer.
    nonisolated private static func stem(_ word: String) -> String {
        guard word.count > 4, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") else { return word }
        return String(word.dropLast())
    }
}
