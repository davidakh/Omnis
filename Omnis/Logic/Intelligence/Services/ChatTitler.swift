import Foundation
import FoundationModels

/// A short name for a chat, from its first question and answer.
@Generable
struct ChatTitle {
    @Guide(description: "A specific two- or three-word title naming the topic, like \"Swift Concurrency\"")
    var title: String
}

/// Names new chats with the chosen model (or the on-device one when it can't generate
/// structured output).
struct ChatTitler {
    let resolver: ModelResolver

    func title(question: String, answer: String) async -> String? {
        guard let model = await resolver.preferred(needsGuidedGeneration: true) else { return nil }
        let session = LanguageModelSession(
            model: model.model,
            instructions: "You name conversations with short, specific titles."
        )
        let prompt = "Title this conversation.\n\nQuestion: \(question.prefix(600))\nAnswer: \(answer.prefix(900))"
        guard let response = try? await session.respond(to: prompt, generating: ChatTitle.self) else { return nil }
        return Self.shortTitle(response.content.title)
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
}
