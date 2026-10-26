import Foundation
import FoundationModels

/// What Omnis says while it works: a sentence up front about what it's doing, a name for the
/// last step before the answer, and whether that step is worth thinking through.
@Generable
struct AskNarration {
    @Guide(description: "true only if a good answer takes careful step-by-step reasoning: math, multi-step logic, debugging or writing code, comparing options, or planning. false for facts, definitions, summaries, rewording, quick lookups and chat")
    var needsReasoning: Bool
    @Guide(description: "One short, friendly first-person sentence telling the user what you're about to do, naming the specific topic or app, like \"Let me look up the latest details about the NFL Draft.\" or \"I'll take a closer look at Messages.\" Never answer the question.")
    var preface: String
    @Guide(description: "A two- to four-word Title Case status for working out the answer, starting with an -ing verb that fits the question, like \"Calculating the Answer\", \"Drafting Your Reply\" or \"Comparing the Options\"")
    var status: String
}

/// Writes the narration with Apple's on-device model, which answers a prompt this small in a
/// moment, so the user sees progress while the screen is read, the web searched or a
/// downloaded model works.
struct AskNarrator {
    /// What the answer is about to do, as decided by `ContextPlanner`.
    struct Plan {
        var question: String
        var needs: ContextNeeds
        /// The app whose window will be read, when the screen is.
        var appName: String?
        var summarizes: Bool
    }

    struct Result {
        var preface: String?
        var status: String?
        var needsReasoning = false
    }

    /// Without Apple's on-device model, a plain sentence still says what's being looked at, and
    /// nothing is thought through (there's no one to decide it's worth the wait).
    func narrate(_ plan: Plan) async -> Result {
        guard let narration = await generate(plan) else {
            return Result(preface: Self.fallbackPreface(for: plan))
        }
        return Result(
            preface: Self.cleanPreface(narration.preface) ?? Self.fallbackPreface(for: plan),
            status: Self.cleanStatus(narration.status),
            needsReasoning: narration.needsReasoning
        )
    }

    private func generate(_ plan: Plan) async -> AskNarration? {
        let model = SystemLanguageModel.default
        guard model.isAvailable else { return nil }
        var steps: [String] = []
        if let query = plan.needs.searchQuery { steps.append("search the web for \"\(query)\"") }
        if !plan.needs.links.isEmpty { steps.append("read the linked page") }
        if plan.needs.screen { steps.append("look at the \(plan.appName.map { "\($0) window" } ?? "window") on the user's screen") }
        if plan.summarizes { steps.append("go over the conversation so far") }
        let session = LanguageModelSession(model: model, instructions: """
            You narrate what an assistant named Omnis is doing while it prepares an answer. \
            Speak as Omnis. Be specific to the user's message and never answer it.
            """)
        let prompt = """
            Message: \(plan.question.prefix(500))
            Omnis will now: \(steps.isEmpty ? "work out the answer" : steps.joined(separator: ", then "))
            """
        let options = GenerationOptions(temperature: 0.4, maximumResponseTokens: 100)
        return try? await session.respond(to: prompt, generating: AskNarration.self, options: options).content
    }

    // MARK: - Cleaning

    /// One sentence, without quotes, ending in punctuation; nil if it ran long or came back empty.
    static func cleanPreface(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
        guard !text.isEmpty, text.count <= 140 else { return nil }
        if let last = text.last, !".!…".contains(last) { text += "." }
        return text
    }

    /// Two to five words starting with an -ing verb, without trailing punctuation ("Calculating
    /// the Answer"); nil otherwise, so a stray sentence never takes the place of "Thinking".
    static func cleanStatus(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = text.split(separator: " ")
        guard (2...5).contains(words.count), text.count <= 32,
              let first = words.first, first.lowercased().hasSuffix("ing") else { return nil }
        return text
    }

    /// What's being looked at, for when the on-device model can't say it.
    static func fallbackPreface(for plan: Plan) -> String? {
        let screen = plan.appName.map { String(localized: "I'll take a closer look at \($0).") }
            ?? String(localized: "I'll give your screen a look.")
        switch (plan.needs.screen, plan.needs.searchQuery != nil, !plan.needs.links.isEmpty) {
        case (true, true, _):
            return String(localized: "I'll look at your screen and search the web.")
        case (true, false, _):
            return screen
        case (false, true, _):
            return String(localized: "Let me search the web for that.")
        case (false, false, true):
            return String(localized: "Let me read that page.")
        default:
            return nil
        }
    }
}
