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
        var isStreaming = true
        var failed = false
        /// Set when the screen should have been included but couldn't be captured.
        var screenNotice: ScreenCaptureError?
        /// The app (and window) the answer looked at, when it used the screen.
        var screenSource: String?
        /// The web pages the answer drew on, when it searched the web.
        var webSources: [WebResult] = []
        /// Set when the web should have been searched but couldn't be.
        var webNotice: String?
        /// When it was asked, and how long the answer took once it was done.
        let askedAt = Date.now
        var duration: TimeInterval?
        /// How fast the model wrote the answer, when it reports its token count.
        var tokensPerSecond: Double?
    }

    private(set) var turns: [Turn] = []
    /// The follow-up being typed, kept across the compact bar.
    var draft = ""
    /// Bumped each time an answer settles, so the chat can refocus its field.
    private(set) var finishedCount = 0

    @ObservationIgnored private unowned let state: AppState
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    /// The saved chat, once the first answer is saved. Observed, so Rename and Delete become
    /// available when it appears.
    private(set) var chatID: UUID?
    /// Reopened from the conversations list, so leaving returns there.
    let isResumed: Bool

    /// Starts answering `question` right away, or opens empty to wait for one.
    init(state: AppState, question: String?) {
        self.state = state
        self.isResumed = false
        if let question { ask(question) }
    }

    /// Reopens a saved chat with its earlier turns, so the conversation can continue; new turns
    /// are saved to the same chat.
    init(state: AppState, resuming chat: Chat) {
        self.state = state
        self.isResumed = true
        self.chatID = chat.id
        turns = chat.orderedTurns.map { Turn(question: $0.question, answer: $0.answer, isStreaming: false) }
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

        let stream = state.ask.answer(question, history: history)
        streamTask = Task {
            do {
                for try await event in stream {
                    switch event {
                    case .status(let status):
                        turns[index].status = status
                    case .screenUnavailable(let reason):
                        turns[index].screenNotice = reason
                    case .screenIncluded(let source):
                        turns[index].screenSource = source
                    case .webIncluded(let sources):
                        turns[index].webSources = sources
                    case .webUnavailable(let reason):
                        turns[index].webNotice = reason
                    case .speed(let tokensPerSecond):
                        turns[index].tokensPerSecond = tokensPerSecond
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
