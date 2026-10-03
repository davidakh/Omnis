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

/// Assembles the context for a question. The same pipeline serves the main ask and asking
/// during a live session, so past sessions are always searchable; a live session only adds
/// its own transcript, ranked first. Everything is fitted to the chosen model's budget.
struct ContextBuilder {
    let index: SessionIndex

    /// Share of the prompt budget each part may use; retrieval gets whatever is left.
    /// Search scores below these are treated as unrelated.
    private static let minimumScore = 0.25
    private static let minimumLiveScore = 0.4

    private enum Share {
        static let history = 0.15
        static let live = 0.35
        static let screen = 0.20
    }

    func build(
        question: String,
        history: [AskTurn],
        live: (startedAt: Date, lines: [LiveLine])?,
        screen: ScreenSnapshot?,
        screenNote: String?,
        model: ResolvedModel
    ) async -> AskContext {
        let budget = model.promptBudget
        var remaining = budget - model.estimatedTokens(question) - 40

        // Earlier turns reach the model as real conversation turns (see `AskService`), not in
        // this prompt, but they still take room in the context window.
        let historyBlock = fit(historyText(history), tokens: Int(Double(budget) * Share.history), model: model)
        remaining -= model.estimatedTokens(historyBlock)

        var liveBlock = ""
        if let live {
            liveBlock = liveText(live, tokens: Int(Double(budget) * Share.live), model: model)
            remaining -= model.estimatedTokens(liveBlock)
        }

        var screenBlock = ""
        if let screen {
            screenBlock = screenText(screen, tokens: Int(Double(budget) * Share.screen), model: model)
            remaining -= model.estimatedTokens(screenBlock)
        } else if let screenNote {
            screenBlock = "On screen: unavailable. \(screenNote)"
        }

        // Past sessions fill the rest. Weak matches are left out so unrelated sessions aren't
        // cited; during a live session only strong matches come in, so the small on-device
        // model doesn't blend past meetings into "this meeting".
        let minimumScore = live == nil ? Self.minimumScore : Self.minimumLiveScore
        var sessionBlocks: [String] = []
        for hit in index.search(question, limit: live == nil ? 12 : 4) where hit.score >= minimumScore {
            let block = hitText(hit)
            let cost = model.estimatedTokens(block)
            guard cost <= remaining else { continue }
            sessionBlocks.append(block)
            remaining -= cost
        }

        var prompt = render(question: question, live: liveBlock, screen: screenBlock, sessions: sessionBlocks)

        // The on-device window is small enough that estimates matter: count exactly and drop
        // the weakest session passages until the prompt fits.
        if model.isOnDevice {
            while !sessionBlocks.isEmpty,
                  let count = try? await SystemLanguageModel.default.tokenCount(for: prompt),
                  count > budget {
                sessionBlocks.removeLast()
                prompt = render(question: question, live: liveBlock, screen: screenBlock, sessions: sessionBlocks)
            }
        }

        return AskContext(
            instructions: instructions(isLive: live != nil, hasScreen: screen != nil),
            prompt: prompt,
            image: model.supportsVision ? screen?.image : nil
        )
    }

    // MARK: - Pieces

    private func instructions(isLive: Bool, hasScreen: Bool) -> String {
        var text = """
        You are Omnis, an assistant on the user's Mac. Use what's relevant: the user's recorded \
        sessions, earlier in this conversation, and their screen when included. Lines labeled \
        "You" are the user. Mention a session only when you use one given below, by its title and \
        date; never make one up, and never label something from this conversation as a session. \
        If they ask about their sessions and the context doesn't say, \
        tell them you couldn't find it; otherwise answer from what you know. Be concise.
        """
        if isLive {
            text += """
             A session is being recorded now. "This session", "this meeting" and "so far" mean \
            only the section headed "This session"; use past sessions only when asked about them.
            """
        }
        if hasScreen {
            text += """
             The window the user is looking at right now is included, as its text under "On screen" \
            and as an image. "This", "here", "on my screen" and "what I'm looking at" refer to it; \
            read it before answering. The screen is not a recorded session, so don't give it a \
            session title or date.
            """
        }
        return text
    }

    private func render(question: String, live: String, screen: String, sessions: [String]) -> String {
        var parts: [String] = []
        if !live.isEmpty { parts.append(live) }
        if !screen.isEmpty { parts.append(screen) }
        if !sessions.isEmpty { parts.append("Past sessions:\n\n" + sessions.joined(separator: "\n\n")) }

        var prompt = parts.isEmpty
            ? """
            Nothing in the user's recorded sessions matches this. If they're asking what someone \
            said or decided in a meeting or call, say you couldn't find it in their sessions; \
            don't guess.

            """
            : parts.joined(separator: "\n\n---\n\n") + "\n"
        prompt += "\nQuestion: \(question)"
        return prompt
    }

    /// For budgeting only: roughly what the earlier turns cost.
    private func historyText(_ history: [AskTurn]) -> String {
        history.suffix(AskService.historyTurns).map { "\($0.question)\n\($0.answer)" }.joined(separator: "\n")
    }

    /// The newest lines that fit, oldest first.
    private func liveText(_ live: (startedAt: Date, lines: [LiveLine]), tokens: Int, model: ResolvedModel) -> String {
        let minutes = Int(Date.now.timeIntervalSince(live.startedAt) / 60)
        let header = "This session (recording now, \(minutes) min in):"
        guard !live.lines.isEmpty else { return "\(header)\nNothing has been said yet." }

        var kept: [String] = []
        var used = model.estimatedTokens(header)
        for line in live.lines.reversed() {
            let text = "\(line.speaker) (\(line.timestamp)): \(line.text)"
            let cost = model.estimatedTokens(text)
            guard used + cost <= tokens else { break }
            kept.append(text)
            used += cost
        }
        let omitted = live.lines.count - kept.count
        let note = omitted > 0 ? "\n(\(omitted) earlier lines omitted)" : ""
        return header + note + "\n" + kept.reversed().joined(separator: "\n")
    }

    private func screenText(_ screen: ScreenSnapshot, tokens: Int, model: ResolvedModel) -> String {
        let title = screen.windowTitle.map { ", \"\($0)\"" } ?? ""
        let header = "On screen, \(screen.appName)\(title):"
        let text = screen.text.isEmpty ? "(No readable text.)" : fit(screen.text, tokens: tokens, model: model)
        return header + "\n" + text
    }

    private func hitText(_ hit: SearchHit) -> String {
        let date = hit.date.formatted(date: .abbreviated, time: .shortened)
        let part: String = switch hit.source {
        case .summary: "summary"
        case .transcript: hit.startOffset.map { "transcript from \(Self.timestamp($0))" } ?? "transcript"
        }
        // Plain prose, so a model that echoes the label still reads naturally.
        return "\(hit.sessionTitle), \(date) (\(part)):\n\(hit.text)"
    }

    private func fit(_ text: String, tokens: Int, model: ResolvedModel) -> String {
        let characters = Int(Double(tokens) * model.charactersPerToken)
        guard text.count > characters else { return text }
        return String(text.prefix(max(0, characters))) + "…"
    }

    private static func timestamp(_ offset: TimeInterval) -> String {
        let seconds = Int(offset)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
