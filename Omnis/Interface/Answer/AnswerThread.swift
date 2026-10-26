import SwiftUI

/// A question thread: each answer streams in from `AskService`, and follow-ups carry the
/// earlier turns as context. Each answered turn is saved to the thread's chat.
///
/// Lives in `AppState.Mode` rather than in a view, so the thread keeps streaming while the
/// surface swaps between the chat and its compact bar.
@Observable
final class AnswerThread: Hashable {
    /// One question and its answer.
    struct Turn: Identifiable {
        let id = UUID()
        let question: String
        /// The answer so far; grows as it streams.
        var answer = ""
        /// What's happening before the first words arrive ("Thinking"…).
        var status = String(localized: "Thinking")
        /// What Omnis said it's doing ("Let me look up…"), if it said so before the answer began.
        /// Shown for this session only; never saved or sent back to the model.
        var preface: String?
        /// About how far along the answer is, 0–99, until its first word.
        var progress: Int?
        var isStreaming = true
        var failed = false
        /// Set when the screen should have been included but couldn't be captured.
        var screenNotice: ScreenCaptureError?
        /// The app (and window) the answer looked at, when it used the screen.
        var screenSource: String?
        /// Just the app it looked at ("Messages").
        var screenApp: String?
        /// About how long the model thought before answering, when it did.
        var thoughtSeconds: Int?
        /// The web pages the answer drew on, when it searched the web.
        var webSources: [WebResult] = []
        /// Set when the web should have been searched but couldn't be.
        var webNotice: String?
        /// When it was asked, and how long the answer took once it was done.
        let askedAt = Date.now
        var duration: TimeInterval?
        /// How fast the model wrote the answer, when it reports its token count.
        var tokensPerSecond: Double?

        /// What happened before the answer, shown between the preface and the answer: the
        /// thinking when there was some, else what was read.
        var step: String? {
            if let seconds = thoughtSeconds {
                return seconds == 1
                    ? String(localized: "Thought for 1 Second")
                    : String(localized: "Thought for \(seconds) Seconds")
            }
            if let app = screenApp, screenNotice == nil {
                return String(localized: "Read the Contents of \(app)")
            }
            if let first = webSources.first {
                return webSources.count == 1
                    ? String(localized: "Read \(first.displayName)")
                    : String(localized: "Searched \(webSources.count) Sites")
            }
            return nil
        }
    }

    private(set) var turns: [Turn] = []
    /// The follow-up being typed, kept across the compact bar.
    var draft = ""
    /// Bumped each time an answer settles, so the chat can refocus its field.
    private(set) var finishedCount = 0

    @ObservationIgnored private unowned let state: AppState
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    /// The summary of the earliest turns once the thread grows long, and how many it covers.
    @ObservationIgnored private var memory = ConversationMemory()
    /// The saved chat, once the first answer is saved. Observed, so Rename and Delete become
    /// available when it appears.
    private(set) var chatID: UUID?
    /// Opened from the conversations list (reopened, or started there as a new chat), so
    /// leaving returns there.
    let isResumed: Bool

    /// Starts answering `question` right away, or opens empty to wait for one.
    /// - Parameter fromList: started from the conversations list, so leaving returns there.
    init(state: AppState, question: String?, fromList: Bool = false) {
        self.state = state
        self.isResumed = fromList
        if let question { ask(question) }
    }

    /// Reopens a saved chat with its earlier turns, so the conversation can continue; new turns
    /// are saved to the same chat.
    init(state: AppState, resuming chat: Chat) {
        self.state = state
        self.isResumed = true
        self.chatID = chat.id
        turns = chat.orderedTurns.map { Turn(question: $0.question, answer: $0.answer, isStreaming: false) }
        memory = ConversationMemory(summary: chat.summary, coveredTurns: min(chat.summarizedTurns, turns.count))
    }

    var isAnswering: Bool { turns.last?.isStreaming ?? false }

    var chat: Chat? {
        chatID.flatMap { id in state.store.chats.first { $0.id == id } }
    }

    /// The saved chat's title (generated, or the user's), else the first question.
    var displayTitle: String {
        chat?.title ?? turns.first?.question ?? ""
    }

    /// The conversation as plain text for sharing: each question, then its answer.
    var shareText: String {
        turns
            .filter { !$0.answer.isEmpty }
            .map { "\(String(localized: "You")): \($0.question)\n\nOmnis: \($0.answer)" }
            .joined(separator: "\n\n")
    }

    func ask(_ question: String) {
        streamTask?.cancel()
        let history = turns
            .filter { !$0.isStreaming && !$0.failed }
            .map { AskTurn(question: $0.question, answer: $0.answer, usedScreen: $0.screenSource != nil, usedWeb: !$0.webSources.isEmpty) }
        turns.append(Turn(question: question))
        let index = turns.count - 1

        let stream = state.ask.answer(question, history: history, memory: memory)
        streamTask = Task {
            do {
                for try await event in stream {
                    switch event {
                    case .status(let status):
                        turns[index].status = status
                    case .screenUnavailable(let reason):
                        turns[index].screenNotice = reason
                    case .screenIncluded(let source, let app):
                        turns[index].screenSource = source
                        turns[index].screenApp = app
                    case .thought(let seconds):
                        turns[index].thoughtSeconds = seconds
                    case .webIncluded(let sources):
                        turns[index].webSources = sources
                    case .webUnavailable(let reason):
                        turns[index].webNotice = reason
                    case .speed(let tokensPerSecond):
                        turns[index].tokensPerSecond = tokensPerSecond
                    case .preface(let preface):
                        // Too late once the answer has started.
                        if turns[index].answer.isEmpty {
                            withAnimation(SurfaceMotion.content) { turns[index].preface = preface }
                        }
                    case .progress(let percent):
                        turns[index].progress = percent
                    case .memory(let memory):
                        self.memory = memory
                        if let chatID { state.store.setMemory(memory, for: chatID) }
                    case .text(let text):
                        if turns[index].answer.isEmpty {
                            withAnimation(SurfaceMotion.content) { turns[index].answer = text }
                        } else {
                            turns[index].answer = text
                        }
                    }
                }
                finish(index)
            } catch is CancellationError {
                // `stop()` already settled the turn, or the thread was left.
            } catch {
                turns[index].answer = AskService.message(for: error)
                turns[index].failed = true
                finish(index)
            }
        }
    }

    /// Stops the answer where it is: whatever has streamed so far becomes the whole answer.
    func stop() {
        streamTask?.cancel()
        guard let index = turns.indices.last, turns[index].isStreaming else { return }
        if turns[index].answer.isEmpty {
            turns[index].answer = String(localized: "Stopped.")
            turns[index].failed = true
        }
        finish(index)
    }

    /// Abandons any answer in flight, for when the thread is closed.
    func cancel() {
        streamTask?.cancel()
    }

    private func finish(_ index: Int) {
        turns[index].duration = Date.now.timeIntervalSince(turns[index].askedAt)
        withAnimation(SurfaceMotion.content) { turns[index].isStreaming = false }
        let turn = turns[index]
        if !turn.failed, !turn.answer.isEmpty {
            let isNewChat = chatID == nil
            let id = state.store.recordTurn(chatID: chatID, question: turn.question, answer: turn.answer)
            chatID = id
            // A new chat starts out named after its question; give it a short title.
            if isNewChat {
                Task { [store = state.store, titler = ChatTitler(resolver: state.resolver)] in
                    if let title = await titler.title(question: turn.question, answer: turn.answer) {
                        store.setGeneratedTitle(title, for: id)
                    }
                }
            }
        }
        finishedCount += 1
    }

    static func == (lhs: AnswerThread, rhs: AnswerThread) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
