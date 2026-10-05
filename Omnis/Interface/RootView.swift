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
            showsGrabber: ![.compact, .live, .liveCompact, .liveAsk, .modelSetup, .permissions].contains(state.mode),
            onQuit: { state.quit() },
            onMinimize: minimizeAction,
            onMaximize: maximizeAction
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
            case .answer(let thread):
                AnswerView(state: state, thread: thread) { state.closeAnswer() }
            case .answerCompact(let thread):
                AnswerCompactBar(state: state, thread: thread) { state.closeAnswer() }
            case .liveAsk: AskBar(state: state, context: .liveSession)
            case .liveAnswer(let thread):
                AnswerView(state: state, thread: thread) { state.mode = .live }
            case .settings: SettingsScreen(state: state)
            case .modelSetup: ModelSetupScreen(state: state)
            case .permissions: PermissionsScreen(state: state)
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
        // Pulling a chat down tucks it into its compact bar rather than closing it.
        case .answer(let thread): { state.mode = .answerCompact(thread) }
        case .answerCompact: nil
        case .liveAsk, .liveAnswer: { state.mode = .live }
        case .settings: { state.closeSettings() }
        case .modelSetup, .permissions: nil
        }
    }

    /// Pulling to the right leaves a session (or a reopened chat) for the sessions list, and the
    /// sessions list for home.
    private var backAction: (() -> Void)? {
        switch state.mode {
        case .session, .sessionCompact: { state.showSessions() }
        case .sessions, .sessionsCompact: { state.closeSessions() }
        case .answer(let thread), .answerCompact(let thread):
            thread.isResumed ? { state.closeAnswer() } : nil
        case .compact, .expanded, .live, .liveCompact, .liveTranscript, .liveAsk, .liveAnswer, .settings, .modelSetup, .permissions: nil
        }
    }

    /// Window controls: the current screen's compact bar, or nil when it's already showing.
    private var minimizeAction: (() -> Void)? {
        switch state.mode {
        case .expanded: { state.mode = .compact }
        case .sessions: { state.mode = .sessionsCompact }
        case .session(let session): { state.mode = .sessionCompact(session) }
        case .answer(let thread): { state.mode = .answerCompact(thread) }
        case .live, .liveTranscript, .liveAsk, .liveAnswer: { state.mode = .liveCompact }
        case .settings: {
            state.closeSettings()
            state.mode = Self.compactForm(of: state.mode) ?? state.mode
        }
        case .compact, .sessionsCompact, .sessionCompact, .answerCompact, .liveCompact, .modelSetup, .permissions: nil
        }
    }

    /// Window controls: the current screen's full view, or nil when it's already showing.
    private var maximizeAction: (() -> Void)? {
        switch state.mode {
        case .compact: { state.mode = .expanded }
        case .sessionsCompact: { state.mode = .sessions }
        case .sessionCompact(let session): { state.mode = .session(session) }
        case .answerCompact(let thread): { state.mode = .answer(thread) }
        case .liveCompact: { state.mode = .live }
        case .expanded, .sessions, .session, .answer, .live, .liveTranscript, .liveAsk, .liveAnswer, .settings, .modelSetup, .permissions: nil
        }
    }

    /// The compact bar for a full screen, for leaving settings straight to it.
    private static func compactForm(of mode: AppState.Mode) -> AppState.Mode? {
        switch mode {
        case .expanded: .compact
        case .sessions: .sessionsCompact
        case .session(let session): .sessionCompact(session)
        case .answer(let thread): .answerCompact(thread)
        case .live, .liveTranscript, .liveAsk, .liveAnswer: .liveCompact
        default: nil
        }
    }

    private var expandAction: (() -> Void)? {
        switch state.mode {
        case .compact: { state.mode = .expanded }
        case .sessionsCompact: { state.mode = .sessions }
        case .sessionCompact(let session): { state.mode = .session(session) }
        case .liveCompact: { state.mode = .live }
        case .answerCompact(let thread): { state.mode = .answer(thread) }
        case .expanded, .sessions, .session, .live, .liveTranscript, .answer, .liveAsk, .liveAnswer, .settings, .modelSetup, .permissions: nil
        }
    }
}
