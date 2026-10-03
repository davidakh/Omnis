import SwiftUI

/// A question thread: each answer streams in from `AskService`, and follow-ups carry the
/// earlier turns as context. Threads from the main ask are saved as chats.
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
        /// What's happening before the first words arrive ("Searching your sessions"…).
        var status = String(localized: "Thinking")
        var isStreaming = true
        var failed = false
        /// Set when the screen should have been included but couldn't be captured.
        var screenNotice: ScreenCaptureError?
        /// The app (and window) the answer looked at, when it used the screen.
        var screenSource: String?
    }

    /// Asking during a live session: its transcript is part of the context, and the thread
    /// isn't saved as a chat.
    let isLive: Bool
    private(set) var turns: [Turn] = []
    /// The follow-up being typed, kept across the compact bar.
    var draft = ""
    /// Bumped each time an answer settles, so the chat can refocus its field.
    private(set) var finishedCount = 0

    @ObservationIgnored private unowned let state: AppState
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var chatID: UUID?

    /// Shown in the top bar instead of the first question (a saved chat's title).
    let title: String?
    /// Reopened from the Chats list, so leaving returns there.
    let isResumed: Bool

    /// Starts answering `question` right away, or opens empty to wait for one.
    init(state: AppState, question: String?, isLive: Bool) {
        self.state = state
        self.isLive = isLive
        self.title = nil
        self.isResumed = false
        if let question { ask(question) }
    }

    /// Reopens a saved chat with its earlier turns, so the conversation can continue; new turns
    /// are saved to the same chat.
    init(state: AppState, resuming chat: Session) {
        self.state = state
        self.isLive = false
        self.title = chat.title
        self.isResumed = true
        self.chatID = chat.id
        var question: String?
        for line in chat.orderedLines {
            if line.speaker == "You" {
                question = line.text
            } else if let asked = question {
                turns.append(Turn(question: asked, answer: line.text, isStreaming: false))
                question = nil
            }
        }
    }

    var isAnswering: Bool { turns.last?.isStreaming ?? false }

    func ask(_ question: String) {
        streamTask?.cancel()
        let history = turns
            .filter { !$0.isStreaming && !$0.failed }
            .map { AskTurn(question: $0.question, answer: $0.answer, usedScreen: $0.screenSource != nil) }
        turns.append(Turn(question: question))
        let index = turns.count - 1

        let stream = state.ask.answer(question, history: history, live: isLive ? state.liveContext : nil)
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

    /// Abandons any answer in flight without saving it, for when the thread is closed.
    func cancel() {
        streamTask?.cancel()
    }

    private func finish(_ index: Int) {
        withAnimation(SurfaceMotion.content) { turns[index].isStreaming = false }
        let turn = turns[index]
        if !isLive, !turn.failed, !turn.answer.isEmpty {
            let isNewChat = chatID == nil
            let id = state.store.recordChatTurn(chatID: chatID, question: turn.question, answer: turn.answer)
            chatID = id
            // A new chat starts out named after its question; give it a short title.
            if isNewChat {
                Task { [processor = state.processor] in
                    await processor.titleChat(id, question: turn.question, answer: turn.answer)
                }
            }
        }
        finishedCount += 1
    }

    static func == (lhs: AnswerThread, rhs: AnswerThread) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
