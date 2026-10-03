import SwiftUI

// MARK: - Answer (mock)

/// One question and its answer in a conversation.
private struct Turn: Identifiable {
    let id = UUID()
    let question: String
    var answer: String
    var revealed = 0          // words of `answer` shown so far
    var thinking = true
}

struct AnswerView: View {
    @Bindable var state: AppState
    /// The first question, or nil to open empty and wait for one.
    let question: String?
    /// Shown in the top bar; defaults to the first question.
    var title: String? = nil
    /// The field's placeholder before anything has been asked.
    var emptyPlaceholder = "Ask anything"
    var answers: [String] = AnswerView.mockAnswers
    let onBack: () -> Void

    @Environment(SurfaceState.self) private var surface: SurfaceState?
    @State private var turns: [Turn] = []
    @State private var followUp = ""
    @State private var streamTask: Task<Void, Never>?
    @State private var thinkingOrb = OrbAnimation(epoch: .now, epochPhase: 0)
    @FocusState private var fieldFocused: Bool

    private static var size: CGSize { CGSize(width: 320, height: 360) }
    private static var topClear: CGFloat { 60 }      // the thread starts just under the top bar …
    private static var bottomClear: CGFloat { 64 }   // … and ends just above the bottom bar
    private static var font: Font { .system(size: 15) }
    private static var lineHeight: AttributedString.LineHeight { .exact(points: 16) }

    private var isAnswering: Bool { turns.last.map { $0.thinking || $0.revealed < words(of: $0).count } ?? false }

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
                TextField(turns.isEmpty ? emptyPlaceholder : "Ask Followup Question", text: $followUp, axis: .vertical)
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

            if turn.thinking {
                ShimmerText("Looking at the Transcript")
                    .font(Self.font)
                    .transition(.opacity)
            } else {
                Text(words(of: turn).prefix(turn.revealed).joined(separator: " "))
                    .font(Self.font)
                    .environment(\.lineHeight, Self.lineHeight)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Streaming

    private func words(of turn: Turn) -> [String] {
        turn.answer.split(separator: " ").map(String.init)
    }

    private func ask(_ question: String) {
        streamTask?.cancel()
        turns.append(Turn(question: question, answer: answers[turns.count % answers.count]))
        let index = turns.count - 1
        streamTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(SurfaceMotion.content) { turns[index].thinking = false }
            let count = words(of: turns[index]).count
            for revealed in 1...count {
                try? await Task.sleep(for: .milliseconds(28))
                guard !Task.isCancelled else { return }
                turns[index].revealed = revealed
            }
            surface?.makeKey?()
            fieldFocused = true
        }
    }

    /// Stops the answer where it is: whatever has streamed so far becomes the whole answer.
    private func stop() {
        streamTask?.cancel()
        guard let index = turns.indices.last else { return }
        let shown = words(of: turns[index]).prefix(turns[index].revealed).joined(separator: " ")
        withAnimation(SurfaceMotion.content) {
            turns[index].answer = shown.isEmpty ? "Stopped." : shown
            turns[index].revealed = words(of: turns[index]).count
            turns[index].thinking = false
        }
        surface?.makeKey?()
        fieldFocused = true
    }

    private func sendFollowUp() {
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnswering else { return }
        followUp = ""
        ask(text)
    }

    static let mockAnswers = [
        """
        You and Roy met on the 1st of October 2026 over Google Meet.

        Roy walked through the open positions on his team, for a designer and for a Swift engineer. \
        You suggested combining the two into a design-to-code role, working with Dimitri on design \
        and with the development team on the front end.

        Roy liked the idea and said he'd check with the hiring manager whether the role could be \
        scoped that way.
        """,
        """
        Yes. Near the end, Roy said he'd like to set up a follow-up interview with the hiring \
        manager once the role is scoped.

        He mentioned aiming for the week of the 12th, and said he'd send a few time slots by email.
        """,
        """
        Based on the transcript, the next steps are:

        • Roy confirms the combined role with the hiring manager.
        • He sends time slots for the follow-up interview.
        • You share two or three portfolio pieces that show both design and code.
        """
    ]
}

extension AnswerView {
    /// Mock answers about the live session (the launch meeting in the live transcript).
    static let liveAnswers = [
        """
        So far, the team is planning the launch of the new onboarding flow.

        Design is nearly done and waiting on welcome-screen copy, expected Thursday. Engineering \
        can start on the locked screens now.
        """,
        """
        The current plan is to ship on the 21st, with the 18th as a stretch goal.

        Sam asked for extra time for the accessibility review, which is why the date moved back \
        from the 18th.
        """,
        """
        Action items so far:

        • Sam: deliver the welcome-screen copy by Thursday.
        • Priya: update the tracker with the new dates.
        • Maya: brief the support team before launch.
        """
    ]
}
