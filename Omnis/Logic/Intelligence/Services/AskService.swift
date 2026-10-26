import Foundation
import FoundationModels
import Synchronization

/// Progress while answering: what's happening, then the answer text as it streams.
enum AskEvent {
    case status(String)
    /// The full answer so far (not a delta).
    case text(String)
    /// The screen was meant to be included but couldn't be captured. Shown under the answer.
    case screenUnavailable(ScreenCaptureError)
    /// The answer looked at the screen: the app and window it read ("Messages · Anna"), and the app.
    case screenIncluded(source: String, app: String)
    /// The answer searched the web: the sources to show under it.
    case webIncluded([WebResult])
    /// The web was meant to be searched but couldn't be. Shown under the answer.
    case webUnavailable(String)
    /// How fast the answer was written: tokens generated per second, from its first word to
    /// its last. Sent once it's done, when the model reports its token count.
    case speed(tokensPerSecond: Double)
    /// Older turns were folded into the conversation's summary: keep it for the next questions.
    case memory(ConversationMemory)
    /// A sentence up front about what Omnis is doing ("Let me look up…"), shown until the answer starts.
    case preface(String)
    /// About how far along the answer is, 0–99, until its first word.
    case progress(Int)
    /// The model thought before answering, for about this many seconds.
    case thought(seconds: Int)
}

/// Thinking went on past its cap without a word of the answer.
private struct ThinkingCapReached: Error {}

/// Set once, read from another task: whether the answer's first word has arrived.
nonisolated private final class FirstWord: Sendable {
    private let arrived = Mutex(false)
    func mark() { arrived.withLock { $0 = true } }
    var hasArrived: Bool { arrived.withLock { $0 } }
}

/// One streamed answer: its text, when its first word came, and the tokens the model reported.
nonisolated private struct Attempt: Sendable {
    var answer = ""
    var firstWord: Date?
    var outputTokens = 0
    var reasoningTokens = 0
    var inputTokens = 0
}

/// The narrated name for the answer's last step ("Calculating the Answer"), which the on-device
/// model may finish writing before or after that step begins.
nonisolated private final class ThinkingStatus: Sendable {
    private let state = Mutex<(label: String?, isThinking: Bool)>((nil, false))

    /// Keeps the label; true if the answer is already at that step, so it should be shown now.
    func set(_ label: String) -> Bool {
        state.withLock { $0.label = label; return $0.isThinking }
    }

    /// The answer has reached its last step: the label to show.
    func begin() -> String {
        state.withLock { $0.isThinking = true; return $0.label ?? String(localized: "Thinking") }
    }
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

    /// - Parameter memory: the summary of the thread's earliest turns, and how many it covers.
    func answer(
        _ question: String,
        history: [AskTurn],
        memory: ConversationMemory = ConversationMemory()
    ) -> AsyncThrowingStream<AskEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let progress = AskProgress()
                let ticker = progress.run(into: continuation)
                defer { ticker.cancel() }
                let thinking = ThinkingStatus()
                progress.advance(to: 0.1, over: 1)
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
                    // A long thread folds its older turns into the summary while the context is
                    // gathered, so the answer still knows the whole conversation.
                    let pending = Array(history.dropFirst(memory.coveredTurns))
                    let summarizes = ConversationSummarizer.needsSummary(pending, model: model)
                    if summarizes {
                        continuation.yield(.status(String(localized: "Summarizing the Conversation")))
                    }
                    async let folded = summarizes
                        ? ConversationSummarizer(resolver: resolver).fold(pending, into: memory, model: model)
                        : nil
                    let (gathered, narration) = await gatherContext(
                        question, previous: history.last, model: model, summarizes: summarizes,
                        progress: progress, thinking: thinking, into: continuation
                    )
                    defer { narration?.cancel() }
                    if summarizes {
                        continuation.yield(.status(String(localized: "Summarizing the Conversation")))
                    }
                    var memory = memory
                    if let updated = await folded {
                        memory = updated
                        continuation.yield(.memory(updated))
                    }
                    try Task.checkCancellation()
                    progress.advance(to: 0.6, over: model.load == nil ? 0.5 : 2)
                    // Whether to think first, as the narration decided; usually known by now.
                    let thinks = model.canThink ? await Self.decision(from: narration, within: 1.5) : false
                    let recent = Array(history.dropFirst(memory.coveredTurns))
                    do {
                        try await respond(
                            question, history: recent, summary: memory.summary, gathered: gathered, model: model,
                            thinks: thinks, progress: progress, thinking: thinking, into: continuation
                        )
                    } catch where [.applePrivateCloud, .local].contains(model.provider) && !(error is CancellationError) {
                        // Network, quota, service or system failures (or a downloaded model that
                        // won't load): retry on device rather than leaving the user without an answer.
                        continuation.yield(.status(String(localized: "Answering on device")))
                        let fallback = try resolver.onDevice()
                        try await respond(
                            question, history: recent, summary: memory.summary, gathered: gathered, model: fallback,
                            thinks: false, progress: progress, thinking: thinking, into: continuation
                        )
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
    /// Once it's decided, the plan is narrated alongside (see `AskNarrator`); that runs on until
    /// the returned task is cancelled or done.
    /// - Parameter summarizes: whether older turns are being summarized meanwhile.
    private func gatherContext(
        _ question: String,
        previous: AskTurn?,
        model: ResolvedModel,
        summarizes: Bool,
        progress: AskProgress,
        thinking: ThinkingStatus,
        into continuation: AsyncThrowingStream<AskEvent, Error>.Continuation
    ) async -> (GatheredContext, narration: Task<Bool, Never>?) {
        // A model that can't see images gets the screen described in words while the web is
        // searched and the model loads.
        let describesScreen = !model.supportsVision
        // Capture and read the screen while the planner decides, when access is already granted
        // (so this never prompts). Thrown away if the question turns out not to need it.
        let early: Task<ScreenSnapshot, Error>? = settings.useScreen && ScreenRecordingPermission.isGranted
            ? Task { try await ScreenContextProvider.capture() }
            : nil
        return await withTaskCancellationHandler {
            let needs = await ContextPlanner(resolver: resolver).plan(
                question, previous: previous, allowsScreen: settings.useScreen, allowsWeb: settings.useWeb
            )
            if !needs.screen { early?.cancel() }
            let narration = narrate(needs, question: question, model: model, summarizes: summarizes, thinking: thinking, into: continuation)
            // Rough times for what's ahead; the percentage only has to feel right.
            let seconds = max(
                needs.searchQuery != nil ? 4 : needs.links.isEmpty ? 0 : 2.5,
                needs.screen ? (describesScreen ? 4 : 1.5) : 0,
                summarizes ? 4 : 0
            )
            if seconds > 0 { progress.advance(to: 0.55, over: seconds) }
            async let screen = captureScreen(
                needs.screen, for: question, early: early, describes: describesScreen, into: continuation
            )
            async let web = searchWeb(needs, into: continuation)
            let (snapshot, screenNote) = await screen
            let (results, webNote) = await web
            return (GatheredContext(screen: snapshot, screenNote: screenNote, web: results, webNote: webNote), narration)
        } onCancel: {
            early?.cancel()
        }
    }

    /// Says what's about to happen ("Let me look up…"), names the last step ("Calculating the
    /// Answer") and decides whether that step is worth thinking through, without holding up the
    /// answer. The task's value is that decision.
    ///
    /// The sentence is shown when there's a wait worth explaining, and always before thinking,
    /// so a longer wait never comes unexplained. Apple's on-device model writes it, so when that
    /// model answers a plain question itself (it can't think), it's left to answer.
    private func narrate(
        _ needs: ContextNeeds,
        question: String,
        model: ResolvedModel,
        summarizes: Bool,
        thinking: ThinkingStatus,
        into continuation: AsyncThrowingStream<AskEvent, Error>.Continuation
    ) -> Task<Bool, Never>? {
        let wantsPreface = needs.screen || needs.usesWeb || summarizes || model.provider == .local
        guard wantsPreface || !model.isOnDevice else { return nil }
        let plan = AskNarrator.Plan(
            question: question,
            needs: needs,
            appName: needs.screen ? ScreenContextProvider.frontmostAppName : nil,
            summarizes: summarizes
        )
        let canThink = model.canThink
        return Task {
            let narration = await AskNarrator().narrate(plan)
            guard !Task.isCancelled else { return false }
            let thinks = canThink && narration.needsReasoning && narration.preface != nil
            if wantsPreface || thinks, let preface = narration.preface {
                continuation.yield(.preface(preface))
            }
            if let status = narration.status, thinking.set(status) { continuation.yield(.status(status)) }
            return thinks
        }
    }

    /// The narration's decision to think, or no if it isn't made within `seconds` (the answer
    /// doesn't wait any longer for it).
    private static func decision(from narration: Task<Bool, Never>?, within seconds: Double) async -> Bool {
        guard let narration else { return false }
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await narration.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false
        }
    }

    /// - Parameter early: a capture already started while planning, used instead of a new one.
    private func captureScreen(
        _ needed: Bool,
        for question: String,
        early: Task<ScreenSnapshot, Error>?,
        describes: Bool,
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
            var snapshot = if let early {
                try await early.value
            } else {
                try await ScreenContextProvider.capture()
            }
            let source = snapshot.windowTitle.map { "\(snapshot.appName) · \($0)" } ?? snapshot.appName
            continuation.yield(.screenIncluded(source: source, app: snapshot.appName))
            if describes {
                snapshot.visualDescription = await ScreenContextProvider.describe(snapshot.image)
            }
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
        summary: String,
        gathered: GatheredContext,
        model: ResolvedModel,
        thinks: Bool,
        progress: AskProgress,
        thinking: ThinkingStatus,
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
        // Usually written while gathering; this covers a fallback model that needs one.
        var snapshot = gathered.screen
        if var shot = snapshot, !model.supportsVision, shot.visualDescription == nil {
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

        continuation.yield(.status(thinking.begin()))
        let thinks = thinks && model.canThink
        let reading = expectedWait(for: model, reading: context, summary: summary, history: history)
        progress.advance(to: 0.95, over: reading + (thinks ? Self.expectedThinking(for: model) : 0))

        var started = Date.now
        var attempt: Attempt
        var thought = thinks
        do {
            // A downloaded model's thinking has no depth setting, so it's held to a time cap
            // (on top of the token cap in `options`); cloud models are held to a moderate level.
            let deadline = thinks && model.provider == .local ? reading + Self.localThinkingSeconds : nil
            attempt = try await stream(context, model: model, thinks: thinks, summary: summary, history: history,
                                       firstWordWithin: deadline, progress: progress, into: continuation)
            // Thinking used up every token before a word of the answer.
            if thinks, attempt.answer.isEmpty { throw ThinkingCapReached() }
        } catch is ThinkingCapReached {
            // Thought too long: answer straight away instead.
            continuation.yield(.status(String(localized: "Wrapping Up")))
            thought = false
            started = .now
            attempt = try await stream(context, model: model, thinks: false, summary: summary, history: history,
                                       firstWordWithin: nil, progress: progress, into: continuation)
        }
        let answer = attempt.answer
        let firstWord = attempt.firstWord

        // About how long it thought: until the first word, less a downloaded model's prompt reading.
        if thought, let firstWord {
            let seconds = firstWord.timeIntervalSince(started) - (model.provider == .local ? reading : 0)
            continuation.yield(.thought(seconds: max(1, Int(seconds.rounded()))))
        }

        // The average speed of writing this answer, without the thinking before it. Tokens as
        // the model reports them, or counted from the answer when it doesn't (exactly on
        // device, estimated otherwise).
        var tokens = max(0, attempt.outputTokens - attempt.reasoningTokens)
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
        // to keep the wait before the first word short. Not after thinking, which isn't reading.
        if model.provider == .local, !thought, let firstWord, let option = settings.localModel {
            LocalModelSpeed.record(
                tokens: attempt.inputTokens,
                seconds: firstWord.timeIntervalSince(started),
                for: option
            )
        }
    }

    /// Streams one answer into `continuation`.
    /// - Parameter firstWordWithin: seconds to wait for the first word before giving up with
    ///   `ThinkingCapReached`; nil to wait as long as it takes.
    private func stream(
        _ context: AskContext,
        model: ResolvedModel,
        thinks: Bool,
        summary: String,
        history: [AskTurn],
        firstWordWithin seconds: Double?,
        progress: AskProgress,
        into continuation: AsyncThrowingStream<AskEvent, Error>.Continuation
    ) async throws -> Attempt {
        let session = Self.session(
            model: model, using: thinks ? model.thinkingModel ?? model.model : model.model,
            instructions: context.instructions, summary: summary, history: history
        )
        let options = Self.options(for: model, thinks: thinks)
        let contextOptions = Self.contextOptions(for: model, thinks: thinks)
        let firstWord = FirstWord()

        return try await withThrowingTaskGroup(of: Attempt?.self) { group in
            group.addTask {
                let stream = if let image = context.image {
                    session.streamResponse(options: options, contextOptions: contextOptions) {
                        context.prompt
                        Attachment(image).label("Screen")
                    }
                } else {
                    session.streamResponse(to: context.prompt, options: options, contextOptions: contextOptions)
                }
                var attempt = Attempt()
                for try await snapshot in stream {
                    if attempt.firstWord == nil, !snapshot.content.isEmpty {
                        attempt.firstWord = .now
                        firstWord.mark()
                        progress.stop()
                    }
                    attempt.answer = snapshot.content
                    attempt.outputTokens = max(attempt.outputTokens, snapshot.usage.output.totalTokenCount)
                    attempt.reasoningTokens = max(attempt.reasoningTokens, snapshot.usage.output.reasoningTokenCount)
                    continuation.yield(.text(snapshot.content))
                }
                attempt.outputTokens = max(attempt.outputTokens, session.usage.output.totalTokenCount)
                attempt.reasoningTokens = max(attempt.reasoningTokens, session.usage.output.reasoningTokenCount)
                attempt.inputTokens = session.usage.input.totalTokenCount
                return attempt
            }
            if let seconds {
                group.addTask {
                    try await Task.sleep(for: .seconds(seconds))
                    return nil
                }
            }
            while let result = try await group.next() {
                if let attempt = result {
                    group.cancelAll()
                    return attempt
                }
                // The cap passed: give up only if the answer hasn't begun.
                if !firstWord.hasArrived {
                    group.cancelAll()
                    throw ThinkingCapReached()
                }
            }
            throw CancellationError()
        }
    }

    /// Seconds a downloaded model may think, after reading the prompt, before it answers
    /// without thinking instead.
    private static let localThinkingSeconds = 20.0
    /// Tokens a downloaded model may spend thinking, on top of the answer's.
    private static let localThinkingTokens = 1_200

    /// About how long thinking adds before the first word, for the percentage.
    private static func expectedThinking(for model: ResolvedModel) -> Double {
        model.provider == .local ? localThinkingSeconds * 0.6 : 6
    }

    /// Thinking is a moderate level, never deep, so it doesn't run long. Without thinking,
    /// cloud models are asked for light reasoning (their own default can run long); a
    /// downloaded model needs no level, as its plain instance doesn't think.
    private static func contextOptions(for model: ResolvedModel, thinks: Bool) -> ContextOptions {
        guard model.canThink, model.provider != .local || thinks else { return ContextOptions() }
        return ContextOptions(reasoningLevel: thinks ? .moderate : .light)
    }

    /// About how long the model takes to start answering, for the percentage. A downloaded
    /// model reads the whole prompt first, at the speed it's been timed reading on this Mac.
    private func expectedWait(for model: ResolvedModel, reading context: AskContext, summary: String, history: [AskTurn]) -> Double {
        switch model.provider {
        case .local:
            let characters = context.instructions.count + context.prompt.count + summary.count
                + history.reduce(0) { $0 + $1.question.count + min($1.answer.count, Self.localHistoryAnswerLength) }
            var tokens = Double(characters) / model.charactersPerToken
            // A screenshot is roughly one token per 28-pixel square.
            if context.image != nil, let dimension = model.maximumImageDimension {
                tokens += pow(Double(dimension) / 28, 2)
            }
            let speed = settings.localModel.map { LocalModelSpeed.promptTokensPerSecond(for: $0) ?? $0.estimatedPromptSpeed } ?? 500
            return tokens / speed + 0.5
        case .appleOnDevice:
            return 1.5
        case .applePrivateCloud:
            return 4
        case .anthropic, .openAI:
            return 2.5
        }
    }

    /// Answers stick close to the context: a low temperature keeps models from wandering into
    /// invented details. Bonsai gets a little more (Qwen-family models can repeat themselves
    /// at the very lowest), but well below the 0.7 used for open-ended chat, since its answers
    /// should only restate what it was given. (The Claude and OpenAI adapters don't send it.)
    /// A downloaded model's thinking counts against its token cap, so thinking adds room for it.
    private static func options(for model: ResolvedModel, thinks: Bool) -> GenerationOptions {
        let thinkingTokens = thinks && model.provider == .local ? localThinkingTokens : 0
        return GenerationOptions(
            temperature: model.provider == .local ? 0.3 : 0.2,
            maximumResponseTokens: model.maximumAnswerTokens.map { $0 + thinkingTokens }
        )
    }

    /// How much of each earlier answer a downloaded model keeps.
    private static let localHistoryAnswerLength = 700

    /// A session that already holds the thread's earlier turns as real prompts and responses,
    /// so follow-ups read as a conversation rather than as more context to quote from. Turns
    /// before those are carried by `summary`, in the instructions.
    /// - Parameter languageModel: `model`'s own model, or its thinking instance.
    private static func session(
        model: ResolvedModel,
        using languageModel: any LanguageModel,
        instructions: String,
        summary: String,
        history: [AskTurn]
    ) -> LanguageModelSession {
        var instructions = instructions
        if !summary.isEmpty {
            instructions += """


            Summary of this conversation before the messages that follow (treat it as what was \
            said earlier):
            \(summary)
            """
        }
        guard !history.isEmpty else {
            return LanguageModelSession(model: languageModel, instructions: instructions)
        }
        func text(_ content: String) -> [Transcript.Segment] { [.text(Transcript.TextSegment(content: content))] }
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                segments: text(instructions),
                toolDefinitions: []
            ))
        ]
        // Normally only the turns the summary doesn't cover yet; capped in case a summary
        // couldn't be written. A downloaded model reads every earlier turn before its first
        // word, so each answer is cut to its opening (enough to know what was said).
        let isLocal = model.provider == .local
        for turn in history.suffix(ConversationSummarizer.maximumTurns(for: model)) {
            let answer = isLocal && turn.answer.count > localHistoryAnswerLength
                ? String(turn.answer.prefix(localHistoryAnswerLength)) + "…"
                : turn.answer
            entries.append(.prompt(Transcript.Prompt(segments: text(turn.question))))
            entries.append(.response(Transcript.Response(assetIDs: [], segments: text(answer))))
        }
        return LanguageModelSession(model: languageModel, transcript: Transcript(entries: entries))
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
