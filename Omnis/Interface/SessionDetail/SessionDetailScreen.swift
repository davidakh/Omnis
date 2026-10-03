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

// MARK: - Session detail

/// The session's generated summary, or its transcript.
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

    @ViewBuilder
    private var summary: some View {
        if let summary = session.summary {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Self.paragraphs(of: summary), id: \.self) { paragraph in
                    Text(paragraph)
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
            ShimmerText(String(localized: "Writing the summary"))
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transcript: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(session.orderedLines) { line in
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
                        .foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static func paragraphs(of summary: String) -> [String] {
        summary.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
