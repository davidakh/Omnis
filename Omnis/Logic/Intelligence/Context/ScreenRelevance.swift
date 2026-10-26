import Foundation

/// Whether a question's wording plainly points at the screen ("this page", "fix this"…).
/// Unclear questions are left to `ContextPlanner`'s model call.
enum ScreenRelevance {
    enum Decision { case needed, unsure }

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

    static func quickDecision(for question: String) -> Decision {
        let text = question.lowercased()
        if screenPhrases.contains(where: text.contains) { return .needed }
        return .unsure
    }
}
