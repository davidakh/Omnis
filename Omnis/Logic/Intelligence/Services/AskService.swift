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
    /// How fast the answer was written: tokens generated per second, from its first word to
    /// its last. Sent once it's done, when the model reports its token count.
    case speed(tokensPerSecond: Double)
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
                    } catch where [.applePrivateCloud, .local].contains(settings.provider) {
                        // Private Cloud Compute can't be used (e.g. not entitled), or no model has
                        // been downloaded: answer with Apple's on-device model.
                        model = try resolver.onDevice()
                    }
                    do {
                        try await respond(question, history: history, live: live, screen: screen, model: model, into: continuation)
                    } catch where [.applePrivateCloud, .local].contains(model.provider) && !(error is CancellationError) {
                        // Network, quota, service or system failures (or a downloaded model that
                        // won't load): retry on device rather than leaving the user without an answer.
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
        guard settings.useScreen else {
            // Plainly about the screen while it's switched off: tell the model it can't see it,
            // so it says so instead of inventing what's there, and show the user why.
            guard ScreenRelevance.quickDecision(for: question) == .needed else { return (nil, nil) }
            continuation.yield(.screenUnavailable(.turnedOff))
            return (nil, ScreenCaptureError.turnedOff.localizedDescription)
        }
        guard await ScreenRelevance(index: builder.index, resolver: resolver).needsScreen(question, previous: previous) else { return (nil, nil) }
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
        // A downloaded model loads into memory on first use (and after macOS reclaims it). Say so
        // when that takes more than a moment, rather than sitting on "Thinking".
        if let load = model.load {
            let loading = Task { try await load.run() }
            let announce = Task {
                try await Task.sleep(for: .milliseconds(300))
                continuation.yield(.status(String(localized: "Loading \(load.name)")))
            }
            try await loading.value
            announce.cancel()
            try Task.checkCancellation()
        }

        // A model that can't see images gets a description of the screen alongside its text.
        var snapshot = screen.snapshot
        if var shot = snapshot, !model.supportsVision {
            continuation.yield(.status(String(localized: "Looking at the screen")))
            shot.visualDescription = await ScreenContextProvider.describe(shot.image)
            snapshot = shot
            try Task.checkCancellation()
        }

        continuation.yield(.status(String(localized: live == nil ? "Searching your sessions" : "Looking at the transcript")))
        let context = await builder.build(
            question: question,
            history: history,
            live: live,
            screen: snapshot,
            screenNote: screen.note,
            model: model,
            canLookUp: model.supportsLookUp
        )
        try Task.checkCancellation()

        // Models that can call tools look details up themselves: a keyword search through a
        // session's transcript (no model, milliseconds) or its summary. Capped per answer, so a
        // question can't turn into minutes of searching. Each lookup shows as the status.
        let budget = LookupBudget(limit: Self.lookupsPerAnswer)
        let listed: @MainActor @Sendable () -> [Session] = { [index = builder.index] in
            index.recentSessions(limit: ContextBuilder.lookupCatalogSize)
        }
        let tools: [any Tool] = model.supportsLookUp ? [
            SearchTranscriptTool(sessions: listed, budget: budget) { continuation.yield(.status($0)) },
            ReadSummaryTool(sessions: listed, budget: budget) { continuation.yield(.status($0)) }
        ] : []

        continuation.yield(.status(String(localized: "Thinking")))
        let session = Self.session(model: model, instructions: context.instructions, history: history, tools: tools)
        let stream = if let image = context.image {
            session.streamResponse(options: Self.options(for: model)) {
                context.prompt
                Attachment(image).label("Screen")
            }
        } else {
            session.streamResponse(to: context.prompt, options: Self.options(for: model))
        }
        let started = Date.now
        var firstWord: Date?
        var answer = ""
        var reported = 0
        for try await snapshot in stream {
            if firstWord == nil, !snapshot.content.isEmpty { firstWord = .now }
            answer = snapshot.content
            reported = max(reported, snapshot.usage.output.totalTokenCount)
            continuation.yield(.text(snapshot.content))
        }
        // The average speed of writing this answer. Tokens as the model reports them, or
        // counted from the answer when it doesn't (exactly on device, estimated otherwise).
        var tokens = max(reported, session.usage.output.totalTokenCount)
        if tokens == 0, !answer.isEmpty {
            tokens = model.isOnDevice
                ? ((try? await SystemLanguageModel.default.tokenCount(for: answer)) ?? model.estimatedTokens(answer))
                : model.estimatedTokens(answer)
        }
        // From the first word to the last; an answer that arrived all at once is timed from
        // when generation began instead.
        var seconds = Date.now.timeIntervalSince(firstWord ?? started)
        if seconds < 0.5 { seconds = Date.now.timeIntervalSince(started) }
        if tokens > 0, seconds > 0 {
            continuation.yield(.speed(tokensPerSecond: Double(tokens) / seconds))
        }
    }

    /// Answers stick close to the context: a low temperature keeps models from wandering into
    /// invented details. Bonsai gets a little more (Qwen-family models can repeat themselves
    /// at the very lowest), but well below the 0.7 used for open-ended chat, since its answers
    /// should only restate what it was given. (The Claude and OpenAI adapters don't send it.)
    private static func options(for model: ResolvedModel) -> GenerationOptions {
        GenerationOptions(
            temperature: model.provider == .local ? 0.3 : 0.2,
            maximumResponseTokens: model.maximumAnswerTokens
        )
    }

    /// Lookups (searches and summaries) one answer may make.
    static let lookupsPerAnswer = 3

    /// How many earlier turns a follow-up carries.
    static let historyTurns = 3

    /// A session that already holds the thread's earlier turns as real prompts and responses,
    /// so follow-ups read as a conversation rather than as more context to quote from.
    private static func session(model: ResolvedModel, instructions: String, history: [AskTurn], tools: [any Tool]) -> LanguageModelSession {
        guard !history.isEmpty else {
            return LanguageModelSession(model: model.model, tools: tools, instructions: instructions)
        }
        func text(_ content: String) -> [Transcript.Segment] { [.text(Transcript.TextSegment(content: content))] }
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                segments: text(instructions),
                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
            ))
        ]
        for turn in history.suffix(historyTurns) {
            entries.append(.prompt(Transcript.Prompt(segments: text(turn.question))))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: text(turn.answer))))
        }
        return LanguageModelSession(model: model.model, tools: tools, transcript: Transcript(entries: entries))
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
