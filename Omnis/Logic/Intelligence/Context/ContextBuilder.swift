import CoreGraphics
import Foundation
import FoundationModels

/// A finished question and answer earlier in the same thread.
struct AskTurn {
    let question: String
    let answer: String
    /// Whether the answer was based on the screen.
    var usedScreen = false
}

/// Everything one question is answered from.
struct AskContext {
    let instructions: String
    let prompt: String
    /// The screen, for models that accept images.
    let image: CGImage?
}

/// Assembles the context for a question: the screen when included, fitted to the chosen
/// model's budget.
struct ContextBuilder {
    /// Share of the prompt budget each part may use.
    private enum Share {
        static let screen = 0.20
    }

    func build(
        question: String,
        history: [AskTurn],
        screen: ScreenSnapshot?,
        screenNote: String?,
        model: ResolvedModel
    ) async -> AskContext {
        let budget = model.answerBudget

        var screenBlock = ""
        if let screen {
            screenBlock = screenText(screen, tokens: Int(Double(budget) * Share.screen), model: model)
        } else if let screenNote {
            screenBlock = "On screen: unavailable. \(screenNote)"
        }

        return AskContext(
            instructions: instructions(hasScreen: screen != nil, screenMissing: screen == nil && screenNote != nil),
            prompt: render(question: question, screen: screenBlock),
            image: model.supportsVision ? screen?.image : nil
        )
    }

    // MARK: - Pieces

    private func instructions(hasScreen: Bool, screenMissing: Bool) -> String {
        var text = """
        You are Omnis, an assistant on the user's Mac. Use what's relevant: earlier in this \
        conversation, and their screen when included. Answer from general knowledge, and say so \
        when unsure. Be concise: a few sentences or a short list, unless they ask for more.
        """
        if hasScreen {
            text += """
             The window the user is looking at right now is included, as its text under "On screen" \
            and as an image. "This", "here", "on my screen" and "what I'm looking at" refer to it; \
            read it before answering.
            """
        }
        if screenMissing {
            text += """
             The user's screen could not be included this time; "On screen" says why. You can't \
            see it, so if they ask about it, tell them that and why, and don't describe or guess \
            what's on it.
            """
        }
        return text
    }

    private func render(question: String, screen: String) -> String {
        guard !screen.isEmpty else { return question }
        return screen + "\n\n---\n\nQuestion: \(question)"
    }

    private func screenText(_ screen: ScreenSnapshot, tokens: Int, model: ResolvedModel) -> String {
        let title = screen.windowTitle.map { ", \"\($0)\"" } ?? ""
        var parts = ["On screen, \(screen.appName)\(title):"]
        if let description = screen.visualDescription, !description.isEmpty {
            parts.append("What it looks like: \(description)")
        }
        if !screen.labels.isEmpty {
            parts.append("Shows: \(screen.labels.joined(separator: ", "))")
        }
        if !screen.codes.isEmpty {
            parts.append("QR codes and barcodes: \(screen.codes.joined(separator: "; "))")
        }
        // Rows in reading order; " | " separates columns and table cells.
        parts.append(screen.text.isEmpty
            ? "Text: (none readable)"
            : "Text (rows in reading order, \" | \" between columns):\n" + fit(screen.text, tokens: tokens, model: model))
        return parts.joined(separator: "\n")
    }

    private func fit(_ text: String, tokens: Int, model: ResolvedModel) -> String {
        let characters = Int(Double(tokens) * model.charactersPerToken)
        guard text.count > characters else { return text }
        return String(text.prefix(max(0, characters))) + "…"
    }
}
