import SwiftUI

/// 320×380: one session's summary or transcript behind its two toolbars.
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
                            .init(value: .transcript, title: "Transcript", symbol: "quote.bubble")
                        ],
                        selection: Bindable(state).detailTab
                    )
                    .zIndex(1)  // the lifted pill floats above the neighbouring buttons
                    Spacer(minLength: 0)
                    SurfaceButton("play.fill", style: .prominent) { state.startSession(compact: false) }
                }
                .frame(height: 32)
            }
            .padding(20)
        }
        .frame(width: 320, height: 380)
    }
}

/// 72 pt capsule: back, session title, play.
struct SessionCompactBar: View {
    let state: AppState
    let session: Session

    var body: some View {
        HStack(spacing: 8) {
            SurfaceButton("chevron.left") { state.showSessions() }
            Text(session.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            SurfaceButton("play.fill", style: .prominent) { state.startSession(compact: false) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(width: 256, height: 72)
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
        if let summary = session.summary ?? draft.flatMap({ $0.isEmpty ? nil : $0 }) {
            VStack(alignment: .leading, spacing: 14) {
                // By position, so a paragraph keeps its place while the draft streams into it.
                ForEach(Array(Self.paragraphs(of: summary).enumerated()), id: \.offset) { _, paragraph in
                    StreamingText(paragraph, revealsInitialText: session.summary == nil)
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
