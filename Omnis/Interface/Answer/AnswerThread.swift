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
        /// Auto answer: instead of one answer, a suggested reply each time the others are
        /// waiting on the user, until stopped.
        var isAuto = false
        /// When it was asked, and how long the answer took once it was done.
        let askedAt = Date.now
        var duration: TimeInterval?
        /// How fast the model wrote the answer, when it reports its token count.
        var tokensPerSecond: Double?
        /// A new summary the model wrote for a session, waiting for the user to save or cancel.
        var proposal: SummaryProposal?
        var suggestions: [Suggestion] = []
    }

    /// A rewritten summary shown in the chat before it replaces the session's.
    struct SummaryProposal {
        enum Status { case writing, ready, saved, cancelled, failed }
        /// Where the draft streams in `SessionProcessor.drafts`.
        let key = UUID()
        let sessionID: UUID
        let title: String
        let time: String
        var text: String?
        var status: Status = .writing
    }

    /// One suggested reply in auto answer.
    struct Suggestion: Identifiable {
        let id: UUID
        /// What the others said that this answers.
        let replyingTo: String
        var text: String
        var isDone = false
    }

    /// Asking during a live session: its transcript is part of the context, and the thread is
    /// saved with the session (in its Chats) rather than as a chat of its own.
    let isLive: Bool
    /// Groups this thread's turns in the live session's Chats.
    @ObservationIgnored private let liveChatID = UUID()
    private(set) var turns: [Turn] = []
    /// The follow-up being typed, kept across the compact bar.
    var draft = ""
    /// Bumped each time an answer settles, so the chat can refocus its field.
    private(set) var finishedCount = 0

    @ObservationIgnored private unowned let state: AppState
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    /// The saved chat, once the first answer is saved (never for live threads). Observed, so
    /// Rename and Delete become available when it appears.
    private(set) var chatID: UUID?

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

    var chat: Session? {
        chatID.flatMap { id in state.store.chats.first { $0.id == id } }
    }

    /// The chat's name once renamed; until then the title it reopened with, or its first question.
    var displayTitle: String {
        if let chat, chat.hasCustomTitle { return chat.title }
        return title ?? turns.first?.question ?? ""
    }

    /// The conversation as plain text for sharing: each question, then its answer.
    var shareText: String {
        turns
            .filter { !$0.answer.isEmpty || !$0.suggestions.isEmpty }
            .map { turn in
                let answer = turn.answer.isEmpty ? turn.suggestions.map(\.text).joined(separator: "\n\n") : turn.answer
                return "\(String(localized: "You")): \(turn.question)\n\nOmnis: \(answer)"
            }
            .joined(separator: "\n\n")
    }

    func ask(_ question: String) {
        // Asking a chat to start a session starts one (leaving the chat, which stays saved).
        if !isLive, !state.recorder.isRecording, SessionCommand.isStartRequest(question) {
            state.startSession(compact: false)
            return
        }
        // "What should I say next?" during a session: keep answering until stopped.
        if isLive, AutoAnswerer.isRequest(question) {
            startAutoAnswer(question)
            return
        }
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
                    case .speed(let tokensPerSecond):
                        turns[index].tokensPerSecond = tokensPerSecond
                    case .summaryProposal(let sessionID, let request, let fromTranscript):
                        propose(in: index, sessionID: sessionID, request: request, fromTranscript: fromTranscript)
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

    // MARK: Summary proposals

    /// Writes the new summary under the answer; it isn't saved until the user says so.
    private func propose(in index: Int, sessionID: UUID, request: String, fromTranscript: Bool) {
        guard let session = state.store.session(withID: sessionID) else { return }
        let proposal = SummaryProposal(sessionID: sessionID, title: session.title, time: session.time)
        withAnimation(SurfaceMotion.content) { turns[index].proposal = proposal }
        let turnID = turns[index].id
        Task { [processor = state.processor] in
            let text = await processor.proposeSummary(for: session, request: request, fromTranscript: fromTranscript, key: proposal.key)
            guard let at = turns.firstIndex(where: { $0.id == turnID }), turns[at].proposal?.status == .writing else { return }
            withAnimation(SurfaceMotion.content) {
                turns[at].proposal?.text = text
                turns[at].proposal?.status = text == nil ? .failed : .ready
            }
            processor.discardDraft(proposal.key)
        }
    }

    /// Replaces the session's summary with the proposal.
    func saveProposal(in turnID: Turn.ID) {
        guard let at = turns.firstIndex(where: { $0.id == turnID }),
              let proposal = turns[at].proposal, proposal.status == .ready, let text = proposal.text,
              let session = state.store.session(withID: proposal.sessionID) else { return }
        withAnimation(SurfaceMotion.content) { turns[at].proposal?.status = .saved }
        Task { [processor = state.processor] in await processor.applySummary(text, to: session) }
    }

    /// Leaves the session's summary as it was.
    func cancelProposal(in turnID: Turn.ID) {
        guard let at = turns.firstIndex(where: { $0.id == turnID }), let proposal = turns[at].proposal else { return }
        withAnimation(SurfaceMotion.content) { turns[at].proposal?.status = .cancelled }
        state.processor.discardDraft(proposal.key)
    }

    /// Auto answer: watches the live transcript and suggests a reply each time the others are
    /// waiting on the user. Runs until `stop()`.
    private func startAutoAnswer(_ question: String) {
        streamTask?.cancel()
        turns.append(Turn(question: question, status: String(localized: "Listening"), isAuto: true))
        let index = turns.count - 1
        let updates = AutoAnswerer(recorder: state.recorder, resolver: state.resolver, index: state.index).updates()
        streamTask = Task {
            for await update in updates {
                switch update {
                case .listening:
                    turns[index].status = String(localized: "Listening")
                case .thinking:
                    turns[index].status = String(localized: "Thinking")
                case .note(let message):
                    turns[index].status = message
                case .suggestion(let id, let replyingTo, let text):
                    if let existing = turns[index].suggestions.firstIndex(where: { $0.id == id }) {
                        turns[index].suggestions[existing].text = text
                    } else {
                        withAnimation(SurfaceMotion.content) {
                            turns[index].suggestions.append(Suggestion(id: id, replyingTo: replyingTo, text: text))
                        }
                    }
                case .finished(let id):
                    if let done = turns[index].suggestions.firstIndex(where: { $0.id == id }) {
                        turns[index].suggestions[done].isDone = true
                    }
                case .discarded(let id):
                    withAnimation(SurfaceMotion.content) { turns[index].suggestions.removeAll { $0.id == id } }
                }
            }
            // Ended on its own (no on-device model, or the session ended).
            if !Task.isCancelled, turns[index].isStreaming { stop() }
        }
    }

    /// Stops the answer where it is: whatever has streamed so far becomes the whole answer.
    /// For auto answer, this is how it's turned off.
    func stop() {
        streamTask?.cancel()
        guard let index = turns.indices.last, turns[index].isStreaming else { return }
        if turns[index].isAuto {
            // Unfinished suggestions go; the rest become the answer follow-ups can refer to.
            turns[index].suggestions.removeAll { !$0.isDone }
            turns[index].answer = turns[index].suggestions.map(\.text).joined(separator: "\n\n")
        }
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
        turns[index].duration = Date.now.timeIntervalSince(turns[index].askedAt)
        withAnimation(SurfaceMotion.content) { turns[index].isStreaming = false }
        let turn = turns[index]
        if isLive, !turn.failed, !turn.answer.isEmpty {
            state.recordLiveTurn(chatID: liveChatID, question: turn.question, answer: turn.answer)
        } else if !turn.failed, !turn.answer.isEmpty {
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
