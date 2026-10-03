import Foundation
import FoundationModels

/// Progress while answering: what's happening, then the answer text as it streams.
enum AskEvent {
    case status(String)
    /// The full answer so far (not a delta).
    case text(String)
    /// The screen was meant to be included but couldn't be captured. Shown under the answer.
    case screenUnavailable(ScreenCaptureError)
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
                    let screen = await captureScreenIfEnabled(continuation)
                    let model = try await resolver.resolve()
                    do {
                        try await respond(question, history: history, live: live, screen: screen, model: model, into: continuation)
                    } catch where model.provider == .applePrivateCloud && Self.isPrivateCloudFailure(error) {
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

    private func captureScreenIfEnabled(
        _ continuation: AsyncThrowingStream<AskEvent, Error>.Continuation
    ) async -> (snapshot: ScreenSnapshot?, note: String?) {
        guard settings.includeScreen else { return (nil, nil) }
        continuation.yield(.status(String(localized: "Looking at the screen")))
        do {
            return (try await ScreenContextProvider.capture(), nil)
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
        let session = LanguageModelSession(model: model.model, instructions: context.instructions)
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

    private static func isPrivateCloudFailure(_ error: Error) -> Bool {
        guard let error = error as? PrivateCloudComputeLanguageModel.Error else { return false }
        switch error {
        case .networkFailure, .serviceUnavailable, .quotaLimitReached: return true
        @unknown default: return false
        }
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
