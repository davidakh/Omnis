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
    /// Sessions listed (title, date, length, definition) for models that read passages.
    private static let catalogSize = 6
    /// Sessions listed for models that look things up themselves; the tools search exactly
    /// these, by title or number.
    static let lookupCatalogSize = 12

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
        model: ResolvedModel,
        canLookUp: Bool = false
    ) async -> AskContext {
        let budget = model.answerBudget
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

        // Every session up front as one line (title, date, length, what it is), so the model
        // tells them apart and answers "what was it about" without reading anything more.
        let catalogBlock = catalogText(index.recentSessions(limit: canLookUp ? Self.lookupCatalogSize : Self.catalogSize))
        remaining -= model.estimatedTokens(catalogBlock)

        var screenBlock = ""
        if let screen {
            screenBlock = screenText(screen, tokens: Int(Double(budget) * Share.screen), model: model)
            remaining -= model.estimatedTokens(screenBlock)
        } else if let screenNote {
            screenBlock = "On screen: unavailable. \(screenNote)"
        }

        // A model that looks things up starts from the list alone and searches for details, so
        // its prompt stays small and the first words come fast. Others get the best-matching
        // passages up front. Weak matches are left out so unrelated sessions aren't cited;
        // during a live session only strong matches come in, so past meetings don't blend into
        // "this meeting".
        var sessionBlocks: [String] = []
        if !canLookUp {
            let minimumScore = live == nil ? Self.minimumScore : Self.minimumLiveScore
            for hit in index.search(question, limit: live == nil ? 12 : 4) where hit.score >= minimumScore {
                let block = hitText(hit)
                let cost = model.estimatedTokens(block)
                guard cost <= remaining else { continue }
                sessionBlocks.append(block)
                remaining -= cost
            }
        }

        var prompt = render(question: question, live: liveBlock, catalog: catalogBlock, screen: screenBlock, sessions: sessionBlocks, canLookUp: canLookUp)

        // The on-device window is small enough that estimates matter: count exactly and drop
        // the weakest session passages until the prompt fits.
        if model.isOnDevice {
            while !sessionBlocks.isEmpty,
                  let count = try? await SystemLanguageModel.default.tokenCount(for: prompt),
                  count > budget {
                sessionBlocks.removeLast()
                prompt = render(question: question, live: liveBlock, catalog: catalogBlock, screen: screenBlock, sessions: sessionBlocks, canLookUp: canLookUp)
            }
        }

        return AskContext(
            instructions: instructions(
                isLive: live != nil,
                hasScreen: screen != nil,
                screenMissing: screen == nil && screenNote != nil,
                canLookUp: canLookUp
            ),
            prompt: prompt,
            image: model.supportsVision ? screen?.image : nil
        )
    }

    // MARK: - Pieces

    private func instructions(isLive: Bool, hasScreen: Bool, screenMissing: Bool, canLookUp: Bool) -> String {
        var text = """
        You are Omnis, an assistant on the user's Mac. Use what's relevant: the user's recorded \
        sessions, earlier in this conversation, and their screen when included. Lines labeled \
        "You" are the user.

        Rules for anything about the user's sessions (who was there, what was said, names, \
        numbers, decisions):
        - State only what a transcript excerpt or summary you were given actually says. Never \
        fill a gap with a likely-sounding name, person, quote or detail.
        - Session titles and the one-line descriptions in the list are written automatically \
        and can be wrong. Use them only to tell sessions apart, never as the source of a name \
        or fact.
        - Each excerpt says which session it's from. Never apply something from one session to \
        another.
        - If what you were given doesn't answer the question, say so plainly, for example "I \
        couldn't find the guest's name in that session." That is a good answer; a guess is not.
        General questions that aren't about their sessions or screen you may answer from general \
        knowledge, and say so when unsure. Be concise: a few sentences or a short list, unless \
        they ask for more.
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
        if canLookUp {
            text += """

            The numbered list below has the user's recent sessions, newest first (number 1 is \
            the latest). A question that doesn't name a session ("the guest", "the host", "the \
            meeting") is about number 1. The list is enough for which sessions exist, when, and \
            roughly what each covers; anything more (names, who said what, details) needs a \
            lookup first: call searchTranscript with the session's number and two to five \
            keywords likely to have been said (a name, a topic, or "welcome guest joining today" \
            to find who was on), or readSummary for an overview. After one or two lookups, answer \
            from what they returned, quoting with the time it was said. If they didn't contain \
            the answer, say you couldn't find it in that session; don't guess. Never ask the user \
            which session they mean.
            When the user asks to change, fix or redo a session's summary (shorter, more detail, \
            a different focus, leave something out), call reviseSummary with the session and \
            their request in their words, then say in one sentence what you're changing; the new \
            summary is shown to them to save or cancel, so don't write it yourself.
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

    private func render(question: String, live: String, catalog: String, screen: String, sessions: [String], canLookUp: Bool) -> String {
        var parts: [String] = []
        if !live.isEmpty { parts.append(live) }
        if !catalog.isEmpty { parts.append(catalog) }
        if !screen.isEmpty { parts.append(screen) }
        if !sessions.isEmpty { parts.append("Past sessions:\n\n" + sessions.joined(separator: "\n\n")) }

        // The catalog alone isn't a match: without passages, there's nothing on what was said.
        var prompt = !canLookUp && sessions.isEmpty && live.isEmpty && screen.isEmpty
            ? (catalog.isEmpty ? "" : catalog + "\n\n") + """
            No passage from the user's recorded sessions matches this. If they're asking what someone \
            said or decided in a meeting or call, say you couldn't find it in their sessions; \
            don't guess.

            """
            : parts.joined(separator: "\n\n---\n\n") + "\n"
        prompt += "\nQuestion: \(question)"
        return prompt
    }

    /// The newest sessions, numbered newest first, each with what it is.
    private func catalogText(_ sessions: [Session]) -> String {
        guard !sessions.isEmpty else { return "The user has no recorded sessions yet." }
        let lines = sessions.enumerated().map { SessionCatalog.line($0.offset + 1, $0.element) }
        return "The user's sessions, newest first (titles are automatic labels):\n" + lines.joined(separator: "\n")
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
