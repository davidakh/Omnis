import SwiftUI

// MARK: - Live session

/// 48 pt capsule, matching the main compact bar: quote, orb, compose.
struct LiveCompactBar: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 4) {
            SurfaceButton("quote.bubble") { state.mode = .liveTranscript }
            LiveOrb(state: state, diameter: 32)
            SurfaceButton("square.and.pencil") { state.askAboutSession() }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
    }
}

/// 72 pt capsule: more, eye, a larger orb, quote, compose.
struct LiveBar: View {
    let state: AppState

    var body: some View {
        LiveControls(state: state, showingTranscript: false)
            .padding(.vertical, 10)
            .padding(.horizontal, 18)
    }
}

/// The live controls row, shared by the live bar and the live transcript.
struct LiveControls: View {
    let state: AppState
    let showingTranscript: Bool

    var body: some View {
        HStack(spacing: 0) {
            // What the session listens to and answers can look at.
            MoreMenu(state: state) {
                Toggle("Microphone", systemImage: "mic", isOn: Bindable(state).usesMicrophone)
                Toggle("System Audio", systemImage: "speaker.wave.2", isOn: Bindable(state).usesSystemAudio)
                Toggle("Screen", systemImage: "macwindow", isOn: Bindable(state).usesScreen)
            }
            // Pause / resume; the orb beside it ends the session.
            SurfaceButton(state.isPaused ? "play.fill" : "pause.fill") { state.togglePause() }
                .padding(.leading, 6)
            if showingTranscript { Spacer(minLength: 12) }
            LiveOrb(state: state, diameter: 52).padding(.horizontal, showingTranscript ? 0 : 12)
            if showingTranscript { Spacer(minLength: 12) }
            SurfaceButton(
                showingTranscript ? "quote.bubble.fill" : "quote.bubble",
                style: showingTranscript ? .prominent : .standard
            ) {
                state.mode = showingTranscript ? .live : .liveTranscript
            }
            SurfaceButton("square.and.pencil") { state.askAboutSession() }.padding(.leading, 6)
        }
    }
}
