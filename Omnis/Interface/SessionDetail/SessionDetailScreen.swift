import SwiftUI

/// 340×400: one session's summary or transcript behind its two toolbars.
struct SessionDetailScreen: View {
    let state: AppState
    let session: Session

    @State private var isRenaming = false

    /// The card shows for sessions with a recording or sections.
    private var showsCard: Bool { session.audioFolder != nil || !session.sections.isEmpty }
    private var isPlayingThis: Bool { state.player.sessionID == session.id }

    var body: some View {
        ZStack {
            SessionDetailContent(
                session: session,
                tab: state.detailTab,
                progress: state.processor.progress[session.id],
                draft: state.processor.drafts[session.id],
                player: showsCard ? state.player : nil,
                playbackTime: isPlayingThis && state.player.hasStarted ? state.player.currentTime : nil,
                isPlaying: isPlayingThis && state.player.isPlaying
            )
            VStack(spacing: 0) {
                // Top toolbar: back, centered title and date, options.
                ZStack {
                    VStack(spacing: 1) {
                        EditableTitle(
                            title: session.title,
                            isEditing: $isRenaming,
                            font: .system(size: 13, weight: .semibold)
                        ) { state.rename(session.id, to: $0) }
                        Text(session.time)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .lineLimit(1)
                    .toolbarTitleShadow()
                    .padding(.horizontal, 40)  // clear of the buttons
                    HStack {
                        SurfaceButton("chevron.left") { state.showSessions() }
                        Spacer()
                        MoreMenu(state: state) {
                            Button("Rename", systemImage: "pencil") { isRenaming = true }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                // Leave first, so nothing is still showing the deleted session.
                                state.showSessions()
                                state.delete([session.id])
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                // Bottom toolbar: share, tabs, play.
                HStack(spacing: 0) {
                    SurfaceShareButton(item: session.shareText, subject: session.title)
                    Spacer(minLength: 0)
                    SurfaceTabBar(
                        tabs: [
                            .init(value: .summary, title: "Summary", symbol: "text.line.2.summary"),
                            .init(value: .transcript, title: "Transcript", symbol: "quote.bubble"),
                            .init(value: .chats, title: "Chats", symbol: "bubble.left.and.bubble.right")
                        ],
                        selection: Bindable(state).detailTab
                    )
                    .zIndex(1)  // the lifted pill floats above the neighbouring buttons
                    Spacer(minLength: 0)
                    // Continues this session rather than starting a new one.
                    SurfaceButton("play.fill", style: .prominent) { state.resumeSession(session, compact: false) }
                }
                .frame(height: 32)
            }
            .padding(20)
        }
        .frame(width: 340, height: 400)
    }
}

/// 72 pt capsule: back, session title and time, play. Widens to fit the whole title, from
/// 256 up to 400 pt; longer titles are truncated.
struct SessionCompactBar: View {
    let state: AppState
    let session: Session

    var body: some View {
        FittingWidth(min: 256, max: 400) {
            HStack(spacing: 12) {
                SurfaceButton("chevron.left") { state.showSessions() }
                VStack(spacing: 1) {
                    Text(session.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(session.time)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                SurfaceButton("play.fill", style: .prominent) { state.resumeSession(session, compact: false) }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 20)
            .frame(height: 72)
        }
    }
}

/// Sizes its content to its ideal width, kept between `min` and `max`, and lays it out at that
/// width, so content wider than `max` truncates instead of overflowing.
private struct FittingWidth: Layout {
    let min: CGFloat
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = Swift.min(Swift.max(content.sizeThatFits(.unspecified).width, min), max)
        let height = content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)).height
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

// MARK: - Session detail

/// The session's generated summary, or its transcript.
private struct SessionDetailContent: View {
    let session: Session
    let tab: AppState.DetailTab
    /// How far along the summary is, while it's being written.
    var progress: String?
    /// The summary so far, while it streams in.
    var draft: String?
    /// Plays the recording; when set, its card leads the summary.
    var player: SessionPlayer?
    /// Where playback is, once started; the transcript highlights that line.
    var playbackTime: TimeInterval?
    /// While playing, the transcript keeps the current line in view.
    var isPlaying = false

    /// The transcript line being played.
    private var currentLine: Int? {
        guard let playbackTime else { return nil }
        return session.orderedLines.last { $0.offset <= playbackTime }?.order
    }

    var body: some View {
        ScrollViewReader { proxy in
            FadingScroll {
                switch tab {
                case .summary: summary
                case .transcript: transcript
                case .chats: chats
                }
            }
            .onChange(of: currentLine) { _, line in
                guard isPlaying, tab == .transcript, let line else { return }
                withAnimation(.smooth(duration: 0.4)) { proxy.scrollTo(line, anchor: .center) }
            }
        }
        .id(tab)  // each tab starts at the top
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            // The recording and its sections scroll with the summary.
            if let player {
                SessionPlayerCard(player: player, session: session)
            }
            summaryText
        }
    }

    @ViewBuilder
    private var summaryText: some View {
        // A summary being written (or rewritten) streams in place of the saved one.
        if let summary = draft.flatMap({ $0.isEmpty ? nil : $0 }) ?? session.summary {
            VStack(alignment: .leading, spacing: 14) {
                // By position, so a paragraph keeps its place while the draft streams into it.
                ForEach(Array(Self.paragraphs(of: summary).enumerated()), id: \.offset) { _, paragraph in
                    StreamingText(paragraph, revealsInitialText: session.summary == nil || draft?.isEmpty == false)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Summaries are written in the background once a session ends.
            ShimmerText(progress ?? String(localized: "Writing the Summary"))
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(session.orderedLines) { line in
                let isCurrent = line.order == currentLine
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(line.speaker)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(line.timestamp)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    Text(line.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.85))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The line being played is lifted, so the transcript can be followed by ear.
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    .white.opacity(isCurrent ? 0.1 : 0),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .padding(.horizontal, -8)
                .id(line.order)
                .animation(.smooth(duration: 0.25), value: isCurrent)
            }
        }
    }

    /// The questions asked while the session recorded: each thread's turns, threads divided.
    @ViewBuilder
    private var chats: some View {
        let threads = session.chats
        if threads.isEmpty {
            // Centered between the toolbars: the 400 pt screen less FadingScroll's clearances.
            VStack(spacing: 14) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                Text("No Chats")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, minHeight: 400 - 64 - 76)
        } else {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(threads.enumerated()), id: \.element.id) { index, chat in
                    if index > 0 {
                        Divider().overlay(.white.opacity(0.05))
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(chat.turns.enumerated()), id: \.offset) { _, turn in
                            chatTurn(turn)
                        }
                    }
                }
            }
        }
    }

    private func chatTurn(_ turn: SessionChat.Turn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .trailing, spacing: 3) {
                Text(turn.timestamp)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
                Text(turn.question)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)

            Text(Self.formatted(turn.answer))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Answers may carry inline markdown, as they do in the chat itself.
    private static func formatted(_ answer: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: answer, options: options)) ?? AttributedString(answer)
    }

    private static func paragraphs(of summary: String) -> [String] {
        summary.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

extension Session {
    /// The session as plain text for sharing: title and date, the summary, then the transcript.
    var shareText: String {
        var parts = ["\(title)\n\(time)"]
        if let summary, !summary.isEmpty { parts.append(summary) }
        let transcript = orderedLines
            .map { "\($0.speaker) (\($0.timestamp)): \($0.text)" }
            .joined(separator: "\n")
        if !transcript.isEmpty { parts.append(transcript) }
        return parts.joined(separator: "\n\n")
    }
}
