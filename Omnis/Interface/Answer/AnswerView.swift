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
    @State private var isRenaming = false
    @State private var thinkingOrb = OrbAnimation(epoch: .now, epochPhase: 0)
    @FocusState private var fieldFocused: Bool

    private static var size: CGSize { CGSize(width: 340, height: 400) }  // matches sessions and session detail
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
            EditableTitle(title: title ?? thread.displayTitle, isEditing: $isRenaming) { name in
                if let id = thread.chatID { state.rename(id, to: name) }
            }
            .toolbarTitleShadow()
            .padding(.horizontal, 44)  // clear of the buttons
            HStack {
                SurfaceButton("chevron.left") { onBack() }
                Spacer()
                ChatMoreMenu(state: state, thread: thread, isRenaming: $isRenaming, onLeave: onBack)
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isAnswering {
                SurfaceShareButton(item: thread.shareText, subject: thread.displayTitle)
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
            // Auto answer grows in place: follow each new suggestion.
            .onChange(of: turns.last?.suggestions.count) {
                guard turns.last?.isAuto == true else { return }
                withAnimation(.smooth(duration: 0.45)) { proxy.scrollTo(Self.autoAnswerEnd, anchor: .bottom) }
            }
            .onChange(of: turns.count) {
                guard let last = turns.last else { return }
                withAnimation(.smooth(duration: 0.45)) { proxy.scrollTo(last.id, anchor: .top) }
            }
        }
        .mask {
            // The same soft fade as `FadingScroll`: from the edges to just past the toolbars.
            let h = Self.size.height
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: (Self.topClear + 8) / h),
                    .init(color: .black, location: (h - Self.bottomClear - 12) / h),
                    .init(color: .clear, location: 1)
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

            // The screen is only read when the question calls for it; say when it was.
            if turn.screenSource != nil, turn.screenNotice == nil {
                Text("Viewed Screen")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                    .transition(.blurReplace)
            }

            if turn.isAuto {
                autoAnswer(turn)
            } else if turn.answer.isEmpty && turn.isStreaming {
                ShimmerText(turn.status)
                    .font(Self.font)
                    .transition(.blurReplace)
            } else {
                StreamingText(Self.formatted(turn.answer), revealsInitialText: turn.isStreaming)
                    .font(Self.font)
                    .environment(\.lineHeight, Self.lineHeight)
                    .foregroundStyle(.white.opacity(turn.failed ? 0.6 : 1))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let proposal = turn.proposal {
                SummaryProposalCard(
                    proposal: proposal,
                    draft: state.processor.drafts[proposal.key],
                    save: { thread.saveProposal(in: turn.id) },
                    cancel: { thread.cancelProposal(in: turn.id) }
                )
                .transition(.blurReplace)
            }

            if let notice = turn.screenNotice {
                ScreenNotice(reason: notice)
                    .transition(.opacity)
            }

            // Only under the latest answer, once it has finished.
            if turn.id == turns.last?.id, !turn.isStreaming {
                HStack(spacing: 8) {
                    FeedbackButton(question: turn.question, answer: turn.answer)
                    Spacer(minLength: 0)
                    // How long it took and how fast it was written: "30s - 15tk/s".
                    if let stats = Self.stats(for: turn) {
                        Text(stats)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                .transition(.opacity)
            }
        }
    }

    /// Auto answer: each suggested reply under a quote of what it answers, newest brightest,
    /// and "Listening" while waiting for the next thing to answer.
    private func autoAnswer(_ turn: AnswerThread.Turn) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(turn.suggestions) { suggestion in
                let isLatest = suggestion.id == turn.suggestions.last?.id
                VStack(alignment: .leading, spacing: 4) {
                    if !suggestion.replyingTo.isEmpty {
                        Text("“\(suggestion.replyingTo)”")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(2)
                    }
                    StreamingText(suggestion.text, revealsInitialText: !suggestion.isDone)
                        .font(Self.font)
                        .environment(\.lineHeight, Self.lineHeight)
                        .foregroundStyle(.white.opacity(isLatest ? 1 : 0.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.blurReplace)
                .animation(SurfaceMotion.content, value: isLatest)
            }
            if turn.isStreaming {
                ShimmerText(turn.status)
                    .font(Self.font)
                    .transition(.blurReplace)
            } else if turn.suggestions.isEmpty {
                Text(turn.answer)
                    .font(Self.font)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Color.clear.frame(height: 1).id(Self.autoAnswerEnd)
        }
        .animation(SurfaceMotion.content, value: turn.suggestions.map(\.id))
        .animation(SurfaceMotion.content, value: turn.isStreaming)
    }

    /// "30s - 15tk/s", or just the time when the model doesn't report tokens.
    private static func stats(for turn: AnswerThread.Turn) -> String? {
        guard let duration = turn.duration, !turn.failed else { return nil }
        let seconds = Int(duration.rounded())
        let time = seconds < 60 ? "\(max(seconds, 1))s" : "\(seconds / 60)m \(seconds % 60)s"
        guard let speed = turn.tokensPerSecond else { return time }
        return "\(time) - \(Int(speed.rounded()))tk/s"
    }

    /// Scroll target that keeps the newest suggestion in view.
    private static let autoAnswerEnd = "auto-answer-end"

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

    @State private var isRenaming = false

    var body: some View {
        HStack(spacing: 8) {
            SurfaceButton("chevron.left") { onBack() }
            Group {
                if let turn = thread.turns.last, turn.isStreaming, turn.answer.isEmpty {
                    ShimmerText(turn.status)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                } else {
                    EditableTitle(title: thread.displayTitle, isEditing: $isRenaming) { name in
                        if let id = thread.chatID { state.rename(id, to: name) }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            if thread.isAnswering {
                SurfaceButton("stop.fill", style: .prominent) { thread.stop() }
                    .transition(.blurReplace)
            } else {
                ChatMoreMenu(state: state, thread: thread, isRenaming: $isRenaming, onLeave: onBack)
                    .transition(.blurReplace)
            }
        }
        .animation(SurfaceMotion.content, value: thread.isAnswering)
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(width: 256, height: 72)
    }
}

/// The chat's more menu: Rename and Delete above Settings. They're available once the chat has
/// been saved; live-session threads are never saved as chats, so they get the plain menu.
private struct ChatMoreMenu: View {
    let state: AppState
    let thread: AnswerThread
    @Binding var isRenaming: Bool
    /// Leaves the chat, as its back button does; Delete leaves before deleting.
    let onLeave: () -> Void

    var body: some View {
        if thread.isLive {
            MoreMenu(state: state)
        } else {
            MoreMenu(state: state) {
                Button("Rename", systemImage: "pencil") { isRenaming = true }
                    .disabled(thread.chatID == nil)
                Button("Delete", systemImage: "trash", role: .destructive) {
                    guard let id = thread.chatID else { return }
                    onLeave()
                    state.delete([id])
                }
                .disabled(thread.chatID == nil)
            }
        }
    }
}

/// A new summary the model wrote, shown before it replaces the session's: the session's title
/// and date, the summary (streaming while it's written), then Cancel and Save.
private struct SummaryProposalCard: View {
    let proposal: AnswerThread.SummaryProposal
    /// The summary so far, while it's being written.
    let draft: String?
    let save: () -> Void
    let cancel: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 22, style: .continuous) }
    private var text: String? { proposal.text ?? draft.flatMap { $0.isEmpty ? nil : $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(proposal.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(proposal.time)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            // A square band across the top; only the card's own outer corners are rounded.
            .background(Rectangle().fill(.white.opacity(0.06)))

            VStack(alignment: .leading, spacing: 14) {
                summary(for: proposal.status)
                footer
            }
            .padding(16)
        }
        .background(.ultraThinMaterial, in: shape)
        .clipShape(shape)
        .animation(SurfaceMotion.content, value: proposal.status)
    }

    @ViewBuilder
    private func summary(for status: AnswerThread.SummaryProposal.Status) -> some View {
        if status == .failed {
            Text("Couldn't write a new summary. The current one is unchanged.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        } else if let text {
            StreamingText(text, revealsInitialText: status == .writing)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(status == .cancelled ? 0.4 : 0.85))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ShimmerText(String(localized: "Writing the new summary"))
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch proposal.status {
        case .writing, .ready:
            HStack(spacing: 10) {
                Button(action: cancel) {
                    Text("Cancel")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                        .background(.white.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                Button(action: save) {
                    Text("Save")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
                        .background(.white, in: Capsule())
                        .contentShape(Capsule())
                }
                .disabled(proposal.status != .ready)
                .opacity(proposal.status == .ready ? 1 : 0.5)
            }
            .buttonStyle(.plain)
        case .saved:
            Label("Saved to the session", systemImage: "checkmark")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        case .cancelled:
            Text("Cancelled. The summary is unchanged.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
        case .failed:
            EmptyView()
        }
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
