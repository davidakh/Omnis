import Foundation
import FoundationModels

/// Progress while answering: what's happening, then the answer text as it streams.
enum AskEvent {
    case status(String)
    /// The full answer so far (not a delta).
    case text(String)
    /// The screen was meant to be included but couldn't be captured. Shown under the answer.
    case screenUnavailable(ScreenCaptureError)
    /// The answer looked at the screen: the app (and window) it read.
    case screenIncluded(String)
}

/// Answers a question with the user's chosen model, from context gathered by
/// `ContextBuilder`. If Private Cloud Compute can't be reached, it answers on device instead.
final class AskService {
    private let resolver: ModelResolver
    private let builder: ContextBuilder
    private let settings: ModelSettings

    init(resolver: ModelResolver, builder: ContextBuilder, settings: ModelSettings) {
        self.resolver = resolver
        self.builder = builder
        self.settings = settings
    }

    /// - Parameter live: the live session's transcript when asking during a session.
    func answer(
        _ question: String,
        history: [AskTurn],
        live: (startedAt: Date, lines: [LiveLine])?
    ) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let screen = await captureScreenIfRelevant(question, previous: history.last, into: continuation)
                    let model: ResolvedModel
                    do {
                        model = try await resolver.resolve()
                    } catch where settings.provider == .applePrivateCloud {
                        // Private Cloud Compute can't be used (e.g. not entitled): answer on device.
                        model = try resolver.onDevice()
                    }
                    do {
                        try await respond(question, history: history, live: live, screen: screen, model: model, into: continuation)
                    } catch where model.provider == .applePrivateCloud && !(error is CancellationError) {
                        // Network, quota, service or system failures: retry on device rather than
                        // leaving the user without an answer.
                        continuation.yield(.status(String(localized: "Answering on device")))
                        let fallback = try resolver.onDevice()
                        try await respond(question, history: history, live: live, screen: screen, model: fallback, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Captures the screen only when the question is about it, so unrelated questions stay fast
    /// and never trigger the Screen Recording prompt.
    private func captureScreenIfRelevant(
        _ question: String,
        previous: AskTurn?,
        into continuation: AsyncThrowingStream<AskEvent, Error>.Continuation
    ) async -> (snapshot: ScreenSnapshot?, note: String?) {
        guard await ScreenRelevance(index: builder.index).needsScreen(question, previous: previous) else { return (nil, nil) }
        continuation.yield(.status(String(localized: "Looking at the screen")))
        do {
            let snapshot = try await ScreenContextProvider.capture()
            let source = snapshot.windowTitle.map { "\(snapshot.appName) · \($0)" } ?? snapshot.appName
            continuation.yield(.screenIncluded(source))
            return (snapshot, nil)
        } catch {
            // Answer anyway: the model is told the screen is missing, and the user sees why.
            let reason = error as? ScreenCaptureError ?? .captureFailed(error.localizedDescription)
            continuation.yield(.screenUnavailable(reason))
            return (nil, reason.localizedDescription)
        }
    }

    private func respond(
        _ question: String,
        history: [AskTurn],
        live: (startedAt: Date, lines: [LiveLine])?,
        screen: (snapshot: ScreenSnapshot?, note: String?),
        model: ResolvedModel,
        into continuation: AsyncThrowingStream<AskEvent, Error>.Continuation
    ) async throws {
        continuation.yield(.status(String(localized: live == nil ? "Searching your sessions" : "Looking at the transcript")))
        let context = await builder.build(
            question: question,
            history: history,
            live: live,
            screen: screen.snapshot,
            screenNote: screen.note,
            model: model
        )
        try Task.checkCancellation()

        continuation.yield(.status(String(localized: "Thinking")))
        let session = Self.session(model: model, instructions: context.instructions, history: history)
        let stream = if let image = context.image {
            session.streamResponse {
                context.prompt
                Attachment(image).label("Screen")
            }
        } else {
            session.streamResponse(to: context.prompt)
        }
        for try await snapshot in stream {
            continuation.yield(.text(snapshot.content))
        }
    }

    /// How many earlier turns a follow-up carries.
    static let historyTurns = 3

    /// A session that already holds the thread's earlier turns as real prompts and responses,
    /// so follow-ups read as a conversation rather than as more context to quote from.
    private static func session(model: ResolvedModel, instructions: String, history: [AskTurn]) -> LanguageModelSession {
        guard !history.isEmpty else {
            return LanguageModelSession(model: model.model, instructions: instructions)
        }
        func text(_ content: String) -> [Transcript.Segment] { [.text(Transcript.TextSegment(content: content))] }
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(segments: text(instructions), toolDefinitions: []))
        ]
        for turn in history.suffix(historyTurns) {
            entries.append(.prompt(Transcript.Prompt(segments: text(turn.question))))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: text(turn.answer))))
        }
        return LanguageModelSession(model: model.model, tools: [], transcript: Transcript(entries: entries))
    }

    /// A short, user-facing explanation for a failed answer.
    static func message(for error: Error) -> String {
        if let error = error as? LanguageModelError {
            switch error {
            case .contextSizeExceeded:
                return String(localized: "That was too much for the model to read at once. Try a narrower question.")
            case .rateLimited:
                return String(localized: "The model is busy. Try again in a moment.")
            case .guardrailViolation, .refusal:
                return String(localized: "The model can't help with that request.")
            case .unsupportedLanguageOrLocale:
                return String(localized: "The model doesn't support this language yet.")
            case .timeout:
                return String(localized: "The model took too long to respond. Try again.")
            default:
                break
            }
        }
        if let error = error as? PrivateCloudComputeLanguageModel.Error, case .quotaLimitReached = error {
            return String(localized: "You've reached today's Private Cloud Compute limit.")
        }
        return error.localizedDescription
    }
}
