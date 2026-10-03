import SwiftUI

/// One question and its answer in a conversation.
private struct Turn: Identifiable {
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
}

/// A question thread: each answer streams in from `AskService`, and follow-ups carry the
/// earlier turns as context. Threads from the main ask are saved as chats.
struct AnswerView: View {
    @Bindable var state: AppState
    /// The first question, or nil to open empty and wait for one.
    let question: String?
    /// Shown in the top bar; defaults to the first question.
    var title: String? = nil
    /// The field's placeholder before anything has been asked.
    var emptyPlaceholder = String(localized: "Ask anything")
    /// Asking during a live session: its transcript is part of the context, and the thread
    /// isn't saved as a chat.
    var isLive = false
    let onBack: () -> Void

    @Environment(SurfaceState.self) private var surface: SurfaceState?
    @State private var turns: [Turn] = []
    @State private var followUp = ""
    @State private var streamTask: Task<Void, Never>?
    @State private var chatID: UUID?
    @State private var thinkingOrb = OrbAnimation(epoch: .now, epochPhase: 0)
    @FocusState private var fieldFocused: Bool

    private static var size: CGSize { CGSize(width: 320, height: 360) }
    private static var topClear: CGFloat { 60 }      // the thread starts just under the top bar …
    private static var bottomClear: CGFloat { 64 }   // … and ends just above the bottom bar
    private static var font: Font { .system(size: 15) }
    private static var lineHeight: AttributedString.LineHeight { .exact(points: 16) }

    private var isAnswering: Bool { turns.last?.isStreaming ?? false }

    var body: some View {
        ZStack {
            thread
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar.frame(minHeight: 32, alignment: .bottom)
            }
            .padding(20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear {
            guard turns.isEmpty else { return }
            if let question {
                ask(question)
            } else {
                surface?.makeKey?()
                fieldFocused = true
            }
        }
        .onDisappear { streamTask?.cancel() }
    }

    // MARK: Bars

    private var topBar: some View {
        ZStack {
            Text(title ?? turns.first?.question ?? "")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 44)  // clear of the buttons
            HStack {
                SurfaceButton("chevron.left") { onBack() }
                Spacer()
                MoreMenu(state: state)
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isAnswering {
                SurfaceButton("square.and.arrow.up") {}
                    .transition(.blurReplace)
                Spacer(minLength: 0)
                SurfaceOrb(animation: thinkingOrb, diameter: 52)
                    .glassEffect(.clear, in: Circle())
                    .frame(height: 32)  // overflows the 32 pt bar, centered on it
                    .transition(.blurReplace)
                Spacer(minLength: 0)
                SurfaceButton("stop.fill", style: .prominent) { stop() }
                    .transition(.blurReplace)
            } else {
                // Fills the bar and grows upward with its text, from a capsule into a rounded rect.
                TextField(turns.isEmpty ? emptyPlaceholder : String(localized: "Ask Followup Question"), text: $followUp, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .foregroundStyle(.white)
                    .lineLimit(1...5)
                    .focused($fieldFocused)
                    .onSubmit(sendFollowUp)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .transition(.blurReplace)
                SurfaceButton("arrow.up", style: .prominent) { sendFollowUp() }
                    .transition(.blurReplace)
            }
        }
        .animation(SurfaceMotion.content, value: isAnswering)
    }

    // MARK: Thread

    private var thread: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(turns) { turn in
                        turnView(turn)
                            .id(turn.id)
                            // The newest turn fills the view, so its question can scroll to the top.
                            .frame(
                                minHeight: turn.id == turns.last?.id
                                    ? Self.size.height - Self.topClear - Self.bottomClear
                                    : nil,
                                alignment: .top
                            )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, Self.topClear)
                .padding(.bottom, Self.bottomClear)
            }
            .scrollIndicators(.hidden)
            .onChange(of: turns.count) {
                guard let last = turns.last else { return }
                withAnimation(.smooth(duration: 0.45)) { proxy.scrollTo(last.id, anchor: .top) }
            }
        }
        .mask {
            let h = Self.size.height
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 40 / h),
                    .init(color: .black, location: 64 / h),
                    .init(color: .black, location: (h - 76) / h),
                    .init(color: .clear, location: (h - 16) / h)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .surfaceScrollable()
    }

    private func turnView(_ turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(turn.question)
                .font(Self.font)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 40)

            if turn.answer.isEmpty && turn.isStreaming {
                ShimmerText(turn.status)
                    .font(Self.font)
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.2), value: turn.status)
                    .transition(.opacity)
            } else {
                Text(Self.formatted(turn.answer))
                    .font(Self.font)
                    .environment(\.lineHeight, Self.lineHeight)
                    .foregroundStyle(.white.opacity(turn.failed ? 0.6 : 1))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let notice = turn.screenNotice {
                ScreenNotice(reason: notice)
                    .transition(.opacity)
            }
        }
    }

    /// Models answer in light markdown; render the inline parts (bold, italics, code) and keep
    /// line breaks. Falls back to the plain text while a partial answer doesn't parse.
    private static func formatted(_ answer: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: answer, options: options)) ?? AttributedString(answer)
    }

    // MARK: Asking

    private func ask(_ question: String) {
        streamTask?.cancel()
        let history = turns
            .filter { !$0.isStreaming && !$0.failed }
            .map { AskTurn(question: $0.question, answer: $0.answer) }
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
                // `stop()` already settled the turn.
            } catch {
                turns[index].answer = AskService.message(for: error)
                turns[index].failed = true
                finish(index)
            }
        }
    }

    private func finish(_ index: Int) {
        withAnimation(SurfaceMotion.content) { turns[index].isStreaming = false }
        let turn = turns[index]
        if !isLive, !turn.failed, !turn.answer.isEmpty {
            chatID = state.store.recordChatTurn(chatID: chatID, question: turn.question, answer: turn.answer)
        }
        surface?.makeKey?()
        fieldFocused = true
    }

    /// Stops the answer where it is: whatever has streamed so far becomes the whole answer.
    private func stop() {
        streamTask?.cancel()
        guard let index = turns.indices.last, turns[index].isStreaming else { return }
        if turns[index].answer.isEmpty {
            turns[index].answer = String(localized: "Stopped.")
            turns[index].failed = true
        }
        finish(index)
    }

    private func sendFollowUp() {
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnswering else { return }
        followUp = ""
        ask(text)
    }
}

/// Why the screen wasn't part of an answer, with a shortcut to grant Screen Recording.
private struct ScreenNotice: View {
    let reason: ScreenCaptureError

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(reason.localizedDescription, systemImage: "macwindow.badge.plus")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            if case .permissionNeeded = reason {
                Button("Open Privacy Settings") { openURL(ScreenCaptureError.settingsURL) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
