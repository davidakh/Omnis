import SwiftUI

/// 320×380, like sessions: the live transcript scrolls behind a title and the live controls.
struct LiveTranscriptScreen: View {
    let state: AppState

    var body: some View {
        ZStack {
            LiveTranscript()
            VStack(spacing: 0) {
                Text("Transcript")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(height: 32)
                Spacer(minLength: 0)
                // The 52 pt orb overflows the 32 pt toolbar row, centered on it.
                LiveControls(state: state, showingTranscript: true)
                    .frame(height: 32)
            }
            .padding(20)
        }
        .frame(width: 320, height: 380)
    }
}

// MARK: - Live transcript (mock data)

/// Mock live transcript, opening at the newest lines. The last line is still being spoken.
private struct LiveTranscript: View {
    var body: some View {
        FadingScroll(anchor: .bottom) {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(Self.lines.enumerated()), id: \.offset) { index, line in
                    let isLive = index == Self.lines.count - 1
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(line.speaker)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                            Text(line.time)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                        Text(line.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(isLive ? 0.6 : 0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private static let lines: [(speaker: String, time: String, text: String)] = [
        ("Maya", "0:04", "Okay, let's get started. Thanks for joining, everyone."),
        ("Maya", "0:09", "The main thing today is the launch timeline for the new onboarding flow."),
        ("Sam", "0:21", "Design is basically done. We're waiting on the final copy for the welcome screens."),
        ("Maya", "0:34", "When do we expect the copy?"),
        ("Sam", "0:37", "End of this week, hopefully Thursday."),
        ("Priya", "0:45", "Engineering can start on the screens that are locked. The welcome copy won't block us."),
        ("Maya", "1:02", "Great. So what's the realistic ship date?"),
        ("Priya", "1:06", "If QA gets a build by the 14th, we can ship the following Tuesday."),
        ("Sam", "1:18", "I'd add a buffer for the accessibility review. It caught a lot last time."),
        ("Maya", "1:27", "Fair. Let's plan on the 21st and treat the 18th as a stretch goal."),
        ("Priya", "1:35", "Works for me. I'll update the tracker after this."),
        ("Maya", "1:41", "And we should loop in support before launch so they're ready for questions…")
    ]
}
