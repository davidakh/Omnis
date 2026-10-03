import Foundation
import FoundationModels

/// What the model writes for a finished session.
@Generable
struct SessionDigest {
    @Guide(description: "A specific title for the session, at most six words")
    var title: String
    @Guide(description: "Two to four short paragraphs covering the topics, decisions and next steps")
    var summary: String
}

/// Runs after a session ends: writes its title and summary, then indexes it. Transcripts
/// longer than the model's window are summarized in parts first, and the part notes are then
/// summarized together.
final class SessionProcessor {
    private let store: SessionStore
    private let index: SessionIndex
    private let resolver: ModelResolver
    private var inFlight: Set<UUID> = []

    init(store: SessionStore, index: SessionIndex, resolver: ModelResolver) {
        self.store = store
        self.index = index
        self.resolver = resolver
    }

    /// Picks up sessions that ended (or were seeded) without finishing, e.g. after a quit.
    func processPending() async {
        for session in store.unprocessedSessions() {
            await process(session)
        }
    }

    func process(_ session: Session) async {
        guard !inFlight.contains(session.id) else { return }
        inFlight.insert(session.id)
        defer { inFlight.remove(session.id) }

        let transcript = session.transcriptText
        if !transcript.isEmpty, let digest = await digest(of: transcript) {
            if !session.hasCustomTitle {
                session.title = digest.title.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
            }
            session.summary = digest.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            session.isProcessed = true
        }
        // Index even without a summary, so the transcript is searchable right away; a later
        // `processPending` adds the summary and re-indexes.
        store.save()
        index.index(session)
    }

    // MARK: - Summarizing

    private func digest(of transcript: String) async -> SessionDigest? {
        let model: ResolvedModel
        if let chosen = try? await resolver.resolve() {
            model = chosen
        } else if let onDevice = try? resolver.onDevice() {
            model = onDevice
        } else {
            return nil
        }
        do {
            return try await digest(of: transcript, model: model)
        } catch where model.provider != .appleOnDevice {
            // Prefer a summary from the on-device model over none at all.
            guard let fallback = try? resolver.onDevice() else { return nil }
            return try? await digest(of: transcript, model: fallback)
        } catch {
            return nil
        }
    }

    private func digest(of transcript: String, model: ResolvedModel) async throws -> SessionDigest {
        let notes = try await condense(transcript, model: model)
        let prompt = """
        Write a title and a summary for this recorded session.

        \(notes.isCondensed ? "Notes from the session" : "Transcript"):
        \(notes.text)
        """
        let session = LanguageModelSession(
            model: model.model,
            instructions: """
            You summarize recorded meetings and conversations accurately and concisely. Lines \
            labeled "You" are the user; refer to them as "you".
            """
        )

        if model.supportsGuidedGeneration {
            return try await session.respond(to: prompt, generating: SessionDigest.self).content
        }
        let reply = try await session.respond(
            to: prompt + "\n\nReply with only the title on the first line, a blank line, then the summary."
        ).content
        var lines = reply.components(separatedBy: "\n")
        let title = lines.isEmpty ? "" : lines.removeFirst()
        return SessionDigest(
            title: title.replacingOccurrences(of: "Title:", with: "").trimmingCharacters(in: .whitespaces),
            summary: lines.joined(separator: "\n")
        )
    }

    /// Shrinks `text` until it fits comfortably in the model's window by summarizing it in
    /// parts. Short transcripts pass through untouched.
    private func condense(_ text: String, model: ResolvedModel) async throws -> (text: String, isCondensed: Bool) {
        let limit = Int(Double(model.promptBudget) * 0.75)
        guard model.estimatedTokens(text) > limit else { return (text, false) }

        var current = text
        while model.estimatedTokens(current) > limit {
            let partCharacters = Int(Double(limit) * 0.8 * model.charactersPerToken)
            var notes: [String] = []
            for part in Self.split(current, maxCharacters: partCharacters) {
                try Task.checkCancellation()
                let session = LanguageModelSession(
                    model: model.model,
                    instructions: "You take concise notes on parts of meeting transcripts."
                )
                let response = try await session.respond(
                    to: "List the key points, decisions and action items in this part, as short bullets:\n\n\(part)"
                )
                notes.append(response.content)
            }
            let condensed = notes.joined(separator: "\n")
            // Guard against a model that doesn't shrink the text.
            guard condensed.count < current.count else { break }
            current = condensed
        }
        return (current, true)
    }

    /// Splits on line boundaries into pieces of at most `maxCharacters`.
    private static func split(_ text: String, maxCharacters: Int) -> [String] {
        var parts: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count + 1 > maxCharacters, !current.isEmpty {
                parts.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
