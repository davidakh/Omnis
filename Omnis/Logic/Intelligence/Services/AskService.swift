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
    /// The answer searched the web: the sources to show under it.
    case webIncluded([WebResult])
    /// The web was meant to be searched but couldn't be. Shown under the answer.
    case webUnavailable(String)
    /// How fast the answer was written: tokens generated per second, from its first word to
    /// its last. Sent once it's done, when the model reports its token count.
    case speed(tokensPerSecond: Double)
}

/// What was gathered for a question besides the conversation: the screen and web results, or
/// why each one that was meant to be included is missing.
private struct GatheredContext {
    var screen: ScreenSnapshot?
    var screenNote: String?
    var web: WebContext?
    var webNote: String?
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

    func answer(
        _ question: String,
        history: [AskTurn]
    ) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let model: ResolvedModel
                    do {
                        model = try await resolver.resolve()
                    } catch where [.applePrivateCloud, .local].contains(settings.provider) {
                        // Private Cloud Compute can't be used (e.g. not entitled), or no model has
                        // been downloaded: answer with Apple's on-device model.
                        model = try resolver.onDevice()
                    }
                    // Start loading a downloaded model while the context is gathered.
                    // `respond` waits for the same load, which is shared and returns at once when done.
                    if let load = model.load {
                        Task { try? await load.run() }
                    }
                    let gathered = await gatherContext(question, previous: history.last, into: continuation)
                    do {
                        try await respond(question, history: history, gathered: gathered, model: model, into: continuation)
                    } catch where [.applePrivateCloud, .local].contains(model.provider) && !(error is CancellationError) {
                        // Network, quota, service or system failures (or a downloaded model that
                        // won't load): retry on device rather than leaving the user without an answer.
                        continuation.yield(.status(String(localized: "Answering on device")))
                        let fallback = try resolver.onDevice()
                        try await respond(question, history: history, gathered: gathered, model: fallback, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decides what the question needs, then captures the screen and searches the web at once.
    /// Each is only used when the question calls for it, so unrelated questions stay fast and
    /// never trigger the Screen Recording prompt.
    private func gatherContext(
        _ question: String,
        previous: AskTurn?,
        into continuation: AsyncThrowingStream<AskEvent, Error>.Continuation
    ) async -> GatheredContext {
        let needs = await ContextPlanner(resolver: resolver).plan(
            question, previous: previous, allowsScreen: settings.useScreen, allowsWeb: settings.useWeb
        )
        async let screen = captureScreen(needs.screen, for: question, into: continuation)
        async let web = searchWeb(needs, into: continuation)
        let (snapshot, screenNote) = await screen
        let (results, webNote) = await web
        return GatheredContext(screen: snapshot, screenNote: screenNote, web: results, webNote: webNote)
    }

    private func captureScreen(
        _ needed: Bool,
        for question: String,
        into continuation: AsyncThrowingStream<AskEvent, Error>.Continuation
    ) async -> (ScreenSnapshot?, String?) {
        guard settings.useScreen else {
            // Plainly about the screen while it's switched off: tell the model it can't see it,
            // so it says so instead of inventing what's there, and show the user why.
            guard ScreenRelevance.quickDecision(for: question) == .needed else { return (nil, nil) }
            continuation.yield(.screenUnavailable(.turnedOff))
            return (nil, ScreenCaptureError.turnedOff.localizedDescription)
        }
        guard needed else { return (nil, nil) }
        continuation.yield(.status(String(localized: "Looking at your Screen")))
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

    private func searchWeb(
        _ needs: ContextNeeds,
        into continuation: AsyncThrowingStream<AskEvent, Error>.Continuation
    ) async -> (WebContext?, String?) {
        guard needs.usesWeb else { return (nil, nil) }
        continuation.yield(.status(needs.searchQuery == nil
            ? String(localized: "Reading the Page")
            : String(localized: "Searching the Web")))
        do {
            let web = try await WebSearch.context(query: needs.searchQuery, links: needs.links)
            continuation.yield(.webIncluded(web.sources))
            return (web, nil)
        } catch {
            // Answer anyway: the model is told the search failed, so it doesn't present
            // remembered facts as current, and the user sees why.
            let reason = (error as? WebSearchError)?.localizedDescription
                ?? WebSearchError.failed(error.localizedDescription).localizedDescription
            continuation.yield(.webUnavailable(reason))
            return (nil, reason)
        }
    }

    private func respond(
        _ question: String,
        history: [AskTurn],
        gathered: GatheredContext,
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
        var snapshot = gathered.screen
        if var shot = snapshot, !model.supportsVision {
            continuation.yield(.status(String(localized: "Looking at your Screen")))
            shot.visualDescription = await ScreenContextProvider.describe(shot.image)
            snapshot = shot
            try Task.checkCancellation()
        }

        let context = await builder.build(
            question: question,
            screen: snapshot,
            screenNote: gathered.screenNote,
            web: gathered.web,
            webNote: gathered.webNote,
            model: model
        )
        try Task.checkCancellation()

        continuation.yield(.status(String(localized: "Thinking")))
        let session = Self.session(model: model, instructions: context.instructions, history: history)
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
        // How fast a downloaded model read this prompt, so later answers size their context
        // to keep the wait before the first word short.
        if model.provider == .local, let firstWord, let option = settings.localModel {
            LocalModelSpeed.record(
                tokens: session.usage.input.totalTokenCount,
                seconds: firstWord.timeIntervalSince(started),
                for: option
            )
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

    /// How many earlier turns a follow-up carries.
    static let historyTurns = 3
    /// The same for a downloaded model, and how much of each earlier answer it keeps.
    private static let localHistoryTurns = 2
    private static let localHistoryAnswerLength = 700

    /// A session that already holds the thread's earlier turns as real prompts and responses,
    /// so follow-ups read as a conversation rather than as more context to quote from.
    private static func session(model: ResolvedModel, instructions: String, history: [AskTurn]) -> LanguageModelSession {
        guard !history.isEmpty else {
            return LanguageModelSession(model: model.model, instructions: instructions)
        }
        func text(_ content: String) -> [Transcript.Segment] { [.text(Transcript.TextSegment(content: content))] }
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                segments: text(instructions),
                toolDefinitions: []
            ))
        ]
        // A downloaded model reads every earlier turn before its first word, so it carries fewer,
        // with each answer cut to its opening (enough to know what was said).
        let isLocal = model.provider == .local
        for turn in history.suffix(isLocal ? localHistoryTurns : historyTurns) {
            let answer = isLocal && turn.answer.count > localHistoryAnswerLength
                ? String(turn.answer.prefix(localHistoryAnswerLength)) + "…"
                : turn.answer
            entries.append(.prompt(Transcript.Prompt(segments: text(turn.question))))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: text(answer))))
        }
        return LanguageModelSession(model: model.model, transcript: Transcript(entries: entries))
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
