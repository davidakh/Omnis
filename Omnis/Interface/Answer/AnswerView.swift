import SwiftUI

/// A question thread (see `AnswerThread`): the conversation scrolling behind its two toolbars.
struct AnswerView: View {
    @Bindable var state: AppState
    @Bindable var thread: AnswerThread
    /// Shown in the top bar; defaults to the first question.
    var title: String? = nil
    /// The field's placeholder before anything has been asked.
    var emptyPlaceholder = String(localized: "Ask anything")
    let onBack: () -> Void

    @Environment(SurfaceState.self) private var surface: SurfaceState?
    @State private var thinkingOrb = OrbAnimation(epoch: .now, epochPhase: 0)
    @FocusState private var fieldFocused: Bool

    private static var size: CGSize { CGSize(width: 320, height: 380) }  // matches sessions and session detail
    private static var topClear: CGFloat { 60 }      // the thread starts just under the top bar …
    private static var bottomClear: CGFloat { 64 }   // … and ends just above the bottom bar
    private static var font: Font { .system(size: 15) }
    private static var lineHeight: AttributedString.LineHeight { .exact(points: 21) }
    private static var bubbleRadius: CGFloat { 20 }

    private var turns: [AnswerThread.Turn] { thread.turns }
    private var isAnswering: Bool { thread.isAnswering }

    var body: some View {
        ZStack {
            conversation
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomBar.frame(minHeight: 32, alignment: .bottom)
            }
            .padding(20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Ready for a follow-up whenever nothing is streaming: on opening empty, on returning
        // from the compact bar, and each time an answer settles.
        .onAppear {
            if !isAnswering { focusField() }
        }
        .onChange(of: thread.finishedCount) { focusField() }
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
                SurfaceButton("stop.fill", style: .prominent) { thread.stop() }
                    .transition(.blurReplace)
            } else {
                // Fills the bar and grows upward with its text, from a capsule into a rounded rect.
                TextField(turns.isEmpty ? emptyPlaceholder : String(localized: "Ask Followup Question"), text: $thread.draft, axis: .vertical)
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

    // MARK: Conversation

    private var conversation: some View {
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
            // A reopened chat starts at its latest exchange.
            .onAppear {
                if turns.count > 1, let last = turns.last { proxy.scrollTo(last.id, anchor: .top) }
            }
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

    private func turnView(_ turn: AnswerThread.Turn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(turn.question)
                .font(Self.font)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: Self.bubbleRadius, style: .continuous))
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
            } else if let source = turn.screenSource {
                // The screen is only read when the question calls for it; say when it was.
                Label(String(localized: "Looked at \(source)"), systemImage: "macwindow")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .transition(.opacity)
            }

            // Only under the latest answer, once it has finished.
            if turn.id == turns.last?.id, !turn.isStreaming {
                FeedbackButton(question: turn.question, answer: turn.answer)
                    .transition(.opacity)
            }
        }
    }

    private static func formatted(_ answer: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: answer, options: options)) ?? AttributedString(answer)
    }

    // MARK: Asking

    private func focusField() {
        surface?.makeKey?()
        fieldFocused = true
    }

    private func sendFollowUp() {
        let text = thread.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isAnswering else { return }
        thread.draft = ""
        thread.ask(text)
    }
}

/// 72 pt capsule: back, the thread's title, and stop while an answer streams.
struct AnswerCompactBar: View {
    let state: AppState
    let thread: AnswerThread
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SurfaceButton("chevron.left") { onBack() }
            Group {
                if let turn = thread.turns.last, turn.isStreaming, turn.answer.isEmpty {
                    ShimmerText(turn.status)
                } else {
                    Text(thread.title ?? thread.turns.first?.question ?? "")
                        .foregroundStyle(.white)
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            if thread.isAnswering {
                SurfaceButton("stop.fill", style: .prominent) { thread.stop() }
                    .transition(.blurReplace)
            } else {
                MoreMenu(state: state)
                    .transition(.blurReplace)
            }
        }
        .animation(SurfaceMotion.content, value: thread.isAnswering)
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(width: 256, height: 72)
    }
}

/// Why the screen wasn't part of an answer, with a shortcut to grant Screen Recording.
private struct ScreenNotice: View {
    let reason: ScreenCaptureError

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(reason.localizedDescription, systemImage: "macwindow")
                .font(.system(size: 11))
                .padding(.horizontal, 2)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            if case .permissionNeeded = reason {
                Button("Open Settings") { openURL(ScreenCaptureError.settingsURL) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 24)
                    .background(.quinary)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
    }
}

/// Opens Mail with a feedback message about the answer above, addressed to the developer.
/// The question and answer are filled in so the report has context; the user can edit them
/// before sending.
private struct FeedbackButton: View {
    let question: String
    let answer: String

    @Environment(\.openURL) private var openURL

    private static let address = "david.akhmedbayev@icloud.com"

    var body: some View {
        Button(action: send) {
            Image(systemName: "exclamationmark.bubble")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 28, height: 28)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(String(localized: "Send Feedback"))
    }

    private func send() {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Self.address
        components.queryItems = [
            URLQueryItem(name: "subject", value: String(localized: "Omnis Feedback")),
            URLQueryItem(name: "body", value: """


                ---
                Question: \(question)

                Answer: \(answer.prefix(1500))
                """)
        ]
        if let url = components.url { openURL(url) }
    }
}
