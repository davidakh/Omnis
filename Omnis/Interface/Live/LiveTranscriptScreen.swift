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

/// The live session's transcript, opening at (and following) the newest line. Finished lines
/// are bright; words still being recognized follow, dimmed, and settle in place.
private struct LiveTranscript: View {
    let recorder: LiveRecorder

    var body: some View {
        FadingScroll(anchor: .bottom) {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let notice = recorder.notice {
                    Label(notice, systemImage: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if recorder.transcriptSoFar.isEmpty {
                    ShimmerText(recorder.status ?? String(localized: "Listening"))
                        .font(.system(size: 13))
                }
                ForEach(recorder.lines) { line in
                    LiveLineView(line: line, isInProgress: false)
                }
                ForEach(recorder.partials) { line in
                    LiveLineView(line: line, isInProgress: true)
                }
            }
            .animation(.smooth(duration: 0.25), value: recorder.lines.count)
        }
    }
}

private struct LiveLineView: View {
    let line: LiveLine
    let isInProgress: Bool

    var body: some View {
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
                .foregroundStyle(.white.opacity(isInProgress ? 0.6 : 0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
