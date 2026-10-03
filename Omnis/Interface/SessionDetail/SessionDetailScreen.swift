import SwiftUI

/// 320×380: one session's summary or transcript behind its two toolbars.
struct SessionDetailScreen: View {
    let state: AppState
    let session: Session

    var body: some View {
        ZStack {
            SessionDetailContent(session: session, tab: state.detailTab)
            VStack(spacing: 0) {
                // Top toolbar: back, centered title and date.
                ZStack {
                    VStack(spacing: 1) {
                        Text(session.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(session.time)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .lineLimit(1)
                    .padding(.horizontal, 40)  // clear of the back button
                    HStack {
                        SurfaceButton("chevron.left") { state.showSessions() }
                        Spacer()
                    }
                }

                Spacer(minLength: 0)

                // Bottom toolbar: share, tabs, play.
                HStack(spacing: 0) {
                    SurfaceButton("text.bubble") {}
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

// MARK: - Session detail (mock data)

/// Mock summary or transcript for one session.
private struct SessionDetailContent: View {
    let session: Session
    let tab: AppState.DetailTab

    var body: some View {
        FadingScroll {
            switch tab {
            case .summary: summary
            case .transcript: transcript
            }
        }
        .id(tab)  // each tab starts at the top
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Self.summaryParagraphs(for: session), id: \.self) { paragraph in
                Text(paragraph)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Array(Self.transcriptLines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 3) {
                    Text(line.speaker)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(line.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static func summaryParagraphs(for session: Session) -> [String] {
        [
            "\(session.title) covered the main goals, the open questions, and a short list of next steps.",
            "The first half focused on what's already done and what's blocked. Most items are on track, with two waiting on input from others.",
            "The second half turned to priorities for the coming week. The top three were agreed, and lower-priority items were moved to a backlog for later review.",
            "Next steps: follow up on the two blocked items, confirm the timeline, and check back at the end of the week."
        ]
    }

    private static let transcriptLines: [(speaker: String, text: String)] = [
        ("You", "Let's go through where things stand."),
        ("Omnis", "Sure. Most items are on track. Two are waiting on input from others."),
        ("You", "Which two?"),
        ("Omnis", "The budget sign-off and the design review. Both were due yesterday."),
        ("You", "Okay, I'll chase those today. What should we prioritise this week?"),
        ("Omnis", "Based on deadlines: finish the draft, confirm the timeline, and prep for Thursday."),
        ("You", "Sounds right. Move everything else to the backlog."),
        ("Omnis", "Done. I'll remind you on Friday to review the backlog."),
        ("You", "Perfect, thanks.")
    ]
}
