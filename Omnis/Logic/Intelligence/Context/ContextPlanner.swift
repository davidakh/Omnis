import Foundation
import FoundationModels

/// What a question needs beyond the conversation itself.
struct ContextNeeds {
    var screen = false
    /// What to search the web for; nil when no search is needed.
    var searchQuery: String?
    /// Links in the question, read directly.
    var links: [URL] = []

    var usesWeb: Bool { searchQuery != nil || !links.isEmpty }
}

@Generable
struct ContextChoice {
    @Guide(description: "true if the answer is in something open on the user's screen right now (document, email, web page, code, error, form)")
    var needsScreen: Bool
    @Guide(description: "true if the answer needs current or specific facts from the internet: news, prices, weather, scores, schedules, recent releases, or details about a particular product, place, company or person")
    var needsWeb: Bool
    @Guide(description: "A short search engine query for those facts when needsWeb is true, otherwise empty")
    var searchQuery: String
}

/// Decides whether a question needs the screen and the web, so each is only used (and the
/// screen permission only asked for) when it matters. Wording settles the obvious cases; one
/// quick call to the on-device model decides the rest, for both at once.
struct ContextPlanner {
    let resolver: ModelResolver

    /// - Parameter previous: the thread's last question and what its answer used, so follow-ups
    ///   like "and tomorrow?" keep looking at the same thing.
    func plan(_ question: String, previous: AskTurn?, allowsScreen: Bool, allowsWeb: Bool) async -> ContextNeeds {
        var needs = ContextNeeds()
        let screenUnsure = allowsScreen && ScreenRelevance.quickDecision(for: question) == .unsure
        needs.screen = allowsScreen && !screenUnsure

        var webUnsure = false
        if allowsWeb {
            needs.links = Self.links(in: question)
            if Self.asksForWeb(question) {
                needs.searchQuery = Self.query(from: question)
            } else {
                // A pasted link is the page to read; searching as well rarely adds anything.
                webUnsure = needs.links.isEmpty
            }
        }

        guard screenUnsure || webUnsure, let choice = await ask(question, previous: previous) else { return needs }
        if screenUnsure { needs.screen = choice.needsScreen }
        if webUnsure, choice.needsWeb {
            let query = choice.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            needs.searchQuery = query.isEmpty ? Self.query(from: question) : String(query.prefix(200))
        }
        return needs
    }

    // MARK: - Wording

    /// Words that ask for something current or for a search. Matched as whole words.
    private static let webWords = try? NSRegularExpression(
        pattern: #"\b(search|look up|look it up|google|on the web|online|internet|latest|newest|news|headlines|today|tonight|tomorrow|yesterday|this week|this weekend|this month|this year|right now|currently|recent|recently|price|prices|stock|weather|forecast|score|scores|who won|release date|come out|came out|open now|near me|20[2-9][0-9])\b"#,
        options: [.caseInsensitive]
    )

    private static func asksForWeb(_ question: String) -> Bool {
        webWords?.firstMatch(in: question, range: NSRange(question.startIndex..., in: question)) != nil
    }

    /// Leading requests that aren't part of what to search for.
    private static let requestPrefixes = [
        "search the web for", "search online for", "search for", "search", "look up", "google",
        "can you", "could you", "please"
    ]

    /// The question as a search query, without "search for…" and the like.
    private static func query(from question: String) -> String {
        var query = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped = true
        while stripped {
            stripped = false
            for prefix in requestPrefixes where query.lowercased().hasPrefix(prefix + " ") {
                query = String(query.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                stripped = true
            }
        }
        return String(query.prefix(200))
    }

    private static func links(in question: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector
            .matches(in: question, range: NSRange(question.startIndex..., in: question))
            .compactMap(\.url)
            .filter { ["http", "https"].contains($0.scheme?.lowercased()) }
    }

    // MARK: - Model

    private func ask(_ question: String, previous: AskTurn?) async -> ContextChoice? {
        // Apple's on-device model first: it's fast at a quick choice, and it leaves a downloaded
        // model's GPU free to load and answer instead of reading this prompt first.
        var resolved = try? resolver.onDevice()
        if resolved == nil { resolved = await resolver.preferred(needsGuidedGeneration: true) }
        guard let model = resolved?.model else { return nil }
        let today = Date.now.formatted(date: .long, time: .omitted)
        let session = LanguageModelSession(model: model, instructions: """
            Decide what the user's message needs. Today is \(today). Examples:
            "What does this function do?" -> screen
            "Can you help me reply?" -> screen
            "Who won the Lakers game?" -> web, query "Lakers game result"
            "What's the weather in Lisbon this weekend?" -> web, query "Lisbon weather this weekend"
            "Is the new MacBook Pro worth it?" -> web, query "new MacBook Pro review"
            "What's the capital of Portugal?" -> neither
            "Give me ideas for a team offsite" -> neither
            """)
        var prompt = "Message: \(question)"
        if let previous {
            let source = previous.usedWeb ? "the web" : previous.usedScreen ? "the screen" : "general knowledge"
            prompt = "Previous message (answered from \(source)): \(previous.question)\n" + prompt
        }
        let options = GenerationOptions(samplingMode: .greedy)
        return try? await session.respond(to: prompt, generating: ContextChoice.self, options: options).content
    }
}
