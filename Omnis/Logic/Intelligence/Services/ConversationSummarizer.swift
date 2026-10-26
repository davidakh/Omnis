import Foundation
import FoundationModels

/// The early part of a long conversation, condensed, so answers still know what was said
/// after those turns stop being sent word for word.
struct ConversationMemory: Equatable {
    var summary = ""
    /// How many of the thread's first turns the summary covers. Later turns are sent as they are.
    var coveredTurns = 0
}

/// Folds older turns into a running summary once a thread outgrows what's worth sending in
/// full, keeping the latest few turns word for word.
struct ConversationSummarizer {
    let resolver: ModelResolver

    /// Latest turns always sent in full: fewer for a downloaded model, which reads every one
    /// before its first word.
    static func recentTurns(for model: ResolvedModel) -> Int {
        model.provider == .local ? 2 : 3
    }

    /// Turns a thread may carry in full before the older ones are summarized, so a summary
    /// is written every few turns rather than on every question.
    static func maximumTurns(for model: ResolvedModel) -> Int {
        recentTurns(for: model) + 3
    }

    /// Share of the answer budget the full turns may use before the older ones are summarized.
    private static let historyShare = 0.30

    /// Whether `pending` (the turns the summary doesn't cover yet) should be folded in now:
    /// there are too many of them, or they take too much of the budget.
    static func needsSummary(_ pending: [AskTurn], model: ResolvedModel) -> Bool {
        guard pending.count > recentTurns(for: model) else { return false }
        if pending.count > maximumTurns(for: model) { return true }
        let tokens = pending.reduce(0) { $0 + model.estimatedTokens($1.question) + model.estimatedTokens($1.answer) }
        return Double(tokens) > Double(model.answerBudget) * historyShare
    }

    /// The memory with every pending turn but the latest few folded into its summary, or nil
    /// if no model could write one (the turns are then tried again on the next question).
    func fold(_ pending: [AskTurn], into memory: ConversationMemory, model: ResolvedModel) async -> ConversationMemory? {
        let folding = Array(pending.dropLast(Self.recentTurns(for: model)))
        guard !folding.isEmpty else { return nil }
        var summary = try? await summarize(folding, after: memory.summary, model: model)
        // The chosen model can fail (network, quota); Apple's on-device model is always close.
        if summary == nil, !model.isOnDevice, let onDevice = try? resolver.onDevice() {
            summary = try? await summarize(folding, after: memory.summary, model: onDevice)
        }
        guard let summary, !summary.isEmpty else { return nil }
        return ConversationMemory(summary: summary, coveredTurns: memory.coveredTurns + folding.count)
    }

    private func summarize(_ turns: [AskTurn], after previous: String, model: ResolvedModel) async throws -> String {
        // About a tenth of what an answer reads, within reason.
        let targetTokens = min(600, max(200, model.answerBudget / 10))
        let words = targetTokens * 3 / 4

        // Summaries aren't answers: they get the model's whole budget. Each turn gets an even
        // share of what's left after the instructions, the earlier summary and the summary itself.
        let available = Int(Double(model.promptBudget - targetTokens - 400) * model.charactersPerToken) - previous.count
        let perTurn = max(400, available / max(1, turns.count))
        let transcript = turns.map { turn in
            let question = String(turn.question.prefix(perTurn / 3))
            let answer = turn.answer.prefix(perTurn - question.count)
            return "User: \(question)\nOmnis: \(answer)\(answer.count < turn.answer.count ? "…" : "")"
        }
        .joined(separator: "\n\n")

        let session = LanguageModelSession(model: model.model, instructions: """
            You keep the memory of a conversation between a user and Omnis, their assistant. \
            Write one summary that lets Omnis continue the conversation without the original \
            messages: what the user asked and wants, facts, names, numbers, decisions and \
            preferences they gave, what Omnis answered or recommended, and anything left open. \
            Keep specifics; drop pleasantries. Plain prose or a short list, at most \(words) words.
            """)
        var prompt = ""
        if !previous.isEmpty {
            prompt += "Summary so far:\n\(previous)\n\nLater messages:\n"
        }
        prompt += transcript + "\n\nWrite the updated summary of the whole conversation."
        let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: targetTokens * 3 / 2)
        let response = try await session.respond(to: prompt, options: options)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
