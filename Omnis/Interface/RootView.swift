import SwiftUI

/// Routes `AppState.mode` to its screen inside the surface host, and decides what
/// collapsing, expanding and pulling back do from each one.
struct RootView: View {
    let state: AppState

    var body: some View {
        SurfaceHost(
            id: state.mode,
            onCollapse: collapseAction,
            onExpand: expandAction,
            onBack: backAction,
            // No grabber on the main compact bar or the live session bars.
            showsGrabber: ![.compact, .live, .liveCompact, .liveAsk].contains(state.mode)
        ) {
            switch state.mode {
            case .compact: HomeBar(state: state)
            case .expanded: AskBar(state: state)
            case .sessions: SessionsScreen(state: state)
            case .sessionsCompact: SessionsCompactBar(state: state)
            case .session(let session): SessionDetailScreen(state: state, session: session)
            case .sessionCompact(let session): SessionCompactBar(state: state, session: session)
            case .live: LiveBar(state: state)
            case .liveCompact: LiveCompactBar(state: state)
            case .liveTranscript: LiveTranscriptScreen(state: state)
            case .answer(let question):
                AnswerView(state: state, question: question) { state.closeAnswer() }
            case .liveAsk: AskBar(state: state, context: .liveSession)
            case .liveAnswer(let question):
                AnswerView(state: state, question: question, isLive: true) { state.mode = .live }
            case .settings: SettingsScreen(state: state)
            }
        }
    }

    private var collapseAction: (() -> Void)? {
        switch state.mode {
        case .compact: nil
        case .expanded: { state.mode = .compact }
        case .sessions: { state.mode = .sessionsCompact }
        case .sessionsCompact: { state.closeSessions() }
        case .session(let session): { state.mode = .sessionCompact(session) }
        case .sessionCompact: nil
        case .live: { state.mode = .liveCompact }
        case .liveCompact: nil
        case .liveTranscript: { state.mode = .live }
        case .answer: { state.closeAnswer() }
        case .liveAsk, .liveAnswer: { state.mode = .live }
        case .settings: { state.closeSettings() }
        }
    }

    /// Pulling to the right leaves a session for the sessions list.
    private var backAction: (() -> Void)? {
        switch state.mode {
        case .session, .sessionCompact: { state.showSessions() }
        case .compact, .expanded, .sessions, .sessionsCompact, .live, .liveCompact, .liveTranscript, .answer, .liveAsk, .liveAnswer, .settings: nil
        }
    }

    private var expandAction: (() -> Void)? {
        switch state.mode {
        case .compact: { state.mode = .expanded }
        case .sessionsCompact: { state.mode = .sessions }
        case .sessionCompact(let session): { state.mode = .session(session) }
        case .liveCompact: { state.mode = .live }
        case .expanded, .sessions, .session, .live, .liveTranscript, .answer, .liveAsk, .liveAnswer, .settings: nil
        }
    }
}
