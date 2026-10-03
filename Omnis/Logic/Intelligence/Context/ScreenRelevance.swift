import Foundation
import FoundationModels

/// Where the on-device model thinks the answer to a question lives.
@Generable
enum AnswerSource {
    case screen, recordings, general
}

@Generable
struct AnswerSourceChoice {
    @Guide(description: """
        screen: something open on the user's screen right now (document, email, web page, code, error, form). \
        recordings: the user's recorded meetings, calls and conversations. \
        general: general knowledge, ideas, writing or planning that needs neither.
        """)
    var source: AnswerSource
}

/// Decides whether a question needs the screen, so it's only captured (and the permission only
/// asked for) when it matters. Wording settles the obvious cases, a strong match with a recorded
/// session means it's about recordings, and anything still ambiguous goes to a quick call from
/// the on-device model.
struct ScreenRelevance {
    enum Decision { case needed, notNeeded, unsure }

    let index: SessionIndex

    /// A search score at or above this means the question is clearly about a recording.
    private static let sessionMatchScore = 0.5

    /// - Parameter previous: the thread's last question, and whether its answer used the
    ///   screen, so follow-ups like "and the total?" keep looking at the same thing.
    func needsScreen(_ question: String, previous: AskTurn?) async -> Bool {
        switch Self.quickDecision(for: question) {
        case .needed: return true
        case .notNeeded: return false
        case .unsure: break
        }
        // A follow-up to a screen answer that doesn't change the subject stays on the screen;
        // otherwise a strong match with a recording means the screen isn't needed.
        if previous?.usedScreen != true,
           let best = index.search(question, limit: 1).first, best.score >= Self.sessionMatchScore {
            return false
        }
        return await ask(question, previous: previous)
    }

    // MARK: - Wording

    /// Phrases that point at the screen.
    private static let screenPhrases = [
        "screen", "looking at", "in front of me", "on my display", "this window", "this tab",
        "this page", "this site", "this website", "this article", "this email", "this message",
        "this thread", "this doc", "this document", "this file", "this pdf", "this code",
        "this function", "this error", "this chart", "this graph", "this table", "this image",
        "this picture", "this photo", "this slide", "this form", "this spreadsheet",
        "this invoice", "what's this", "what is this", "read this", "summarize this",
        "explain this", "translate this", "reply to this", "respond to this", "fix this",
        "highlighted", "selected text", "what i have open"
    ]

    /// Phrases that point at recordings or past conversations instead.
    private static let sessionPhrases = [
        "meeting", "session", "call with", "on the call", "transcript", "recording", "recorded",
        "discussed", "talked about", "say about", "said", "mentioned", "agreed", "decided",
        "action item", "follow-up", "follow up", "yesterday", "last week", "earlier today",
        "this morning"
    ]

    static func quickDecision(for question: String) -> Decision {
        let text = question.lowercased()
        if screenPhrases.contains(where: text.contains) { return .needed }
        if sessionPhrases.contains(where: text.contains) { return .notNeeded }
        return .unsure
    }

    // MARK: - Model

    private func ask(_ question: String, previous: AskTurn?) async -> Bool {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return false }
        let session = LanguageModelSession(model: model, instructions: """
            Decide where the answer to the user's message is found. Examples:
            "What does this function do?" -> screen
            "Can you help me reply?" -> screen
            "When is the launch date?" -> recordings
            "What did Sam promise to send?" -> recordings
            "What's the capital of Portugal?" -> general
            "Give me ideas for a team offsite" -> general
            """)
        var prompt = "Message: \(question)"
        if let previous {
            let source = previous.usedScreen ? "screen" : "not the screen"
            prompt = "Previous message (answered from \(source)): \(previous.question)\n" + prompt
        }
        let options = GenerationOptions(samplingMode: .greedy)
        let response = try? await session.respond(to: prompt, generating: AnswerSourceChoice.self, options: options)
        return response?.content.source == .screen
    }
}
