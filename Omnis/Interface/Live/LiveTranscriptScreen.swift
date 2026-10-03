import SwiftUI

/// 320×380, like sessions: the live transcript scrolls behind a title and the live controls.
struct LiveTranscriptScreen: View {
    let state: AppState

    var body: some View {
        ZStack {
            LiveTranscript(recorder: state.recorder)
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

// MARK: - Live transcript

/// The live session's transcript, opening at (and following) the newest line, which is
/// dimmed while it's still being spoken.
private struct LiveTranscript: View {
    let recorder: LiveRecorder

    var body: some View {
        FadingScroll(anchor: .bottom) {
            LazyVStack(alignment: .leading, spacing: 12) {
                if recorder.lines.isEmpty {
                    ShimmerText(String(localized: "Listening"))
                        .font(.system(size: 13))
                }
                ForEach(recorder.lines) { line in
                    let isLive = line.id == recorder.lines.last?.id && !recorder.isPaused
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
                            .foregroundStyle(.white.opacity(isLive ? 0.6 : 0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .animation(.smooth(duration: 0.25), value: recorder.lines.count)
        }
    }
}
