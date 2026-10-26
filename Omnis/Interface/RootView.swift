import SwiftUI

/// Routes `AppState.mode` to its screen inside the surface host, and decides what
/// collapsing, expanding and pulling back do from each one. The list and chats have compact
/// bars; the ask bar, settings and setup screens don't.
struct RootView: View {
    let state: AppState

    var body: some View {
        SurfaceHost(
            id: surfaceID,
            onCollapse: collapseAction,
            onExpand: expandAction,
            onBack: backAction,
            // No grabber on the main ask bar.
            showsGrabber: ![.expanded, .modelSetup, .permissions].contains(state.mode),
            onQuit: { state.quit() },
            onMinimize: minimizeAction,
            onMaximize: expandAction
        ) {
            switch state.mode {
            case .expanded: AskBar(state: state)
            case .conversations: ConversationsScreen(state: state)
            case .conversationsCompact: ConversationsCompactBar(state: state)
            case .answer(let thread):
                ChatSplitView(state: state, thread: thread) { state.closeAnswer() }
            case .answerCompact(let thread):
                AnswerCompactBar(state: state, thread: thread) { state.closeAnswer() }
            case .settings: SettingsScreen(state: state)
            case .modelSetup: ModelSetupScreen(state: state)
            case .permissions: PermissionsScreen(state: state)
            }
        }
    }

    /// Switching chats from the sidebar keeps the surface in place; only the chat pane swaps.
    /// The same goes for the compact bar.
    private var surfaceID: AnyHashable {
        switch state.mode {
        case .answer: "answer"
        case .answerCompact: "answerCompact"
        default: state.mode
        }
    }

    /// Pulling down tucks the list or a chat into its compact bar rather than closing it.
    private var collapseAction: (() -> Void)? {
        switch state.mode {
        case .settings: { state.closeSettings() }
        case .conversations, .answer: minimizeAction
        case .expanded, .conversationsCompact, .answerCompact, .modelSetup, .permissions: nil
        }
    }

    /// Pulling up (or the expand control) brings a compact bar back to its full screen.
    private var expandAction: (() -> Void)? {
        switch state.mode {
        case .conversationsCompact: { state.mode = .conversations }
        case .answerCompact(let thread): { state.mode = .answer(thread) }
        case .expanded, .conversations, .answer, .settings, .modelSetup, .permissions: nil
        }
    }

    /// Window controls: the current screen's compact bar, or nil when there isn't one (or
    /// it's already showing).
    private var minimizeAction: (() -> Void)? {
        switch state.mode {
        case .settings(let previous):
            guard let compact = Self.compactForm(of: previous) else { return nil }
            return { state.mode = compact }
        default:
            guard let compact = Self.compactForm(of: state.mode) else { return nil }
            return { state.mode = compact }
        }
    }

    /// The compact bar for a full screen.
    private static func compactForm(of mode: AppState.Mode) -> AppState.Mode? {
        switch mode {
        case .conversations: .conversationsCompact
        case .answer(let thread): .answerCompact(thread)
        default: nil
        }
    }

    /// Pulling to the right leaves a reopened chat for the list, and the list for home.
    private var backAction: (() -> Void)? {
        switch state.mode {
        case .conversations, .conversationsCompact: { state.closeConversations() }
        case .answer(let thread), .answerCompact(let thread):
            thread.isResumed ? { state.closeAnswer() } : nil
        case .expanded, .settings, .modelSetup, .permissions: nil
        }
    }
}
