import SwiftUI

/// Routes `AppState.mode` to its screen inside the surface host, and decides what
/// collapsing and pulling back do from each one. No screen has a compact form.
struct RootView: View {
    let state: AppState

    var body: some View {
        SurfaceHost(
            id: state.mode,
            onCollapse: collapseAction,
            onBack: backAction,
            // No grabber on the main ask bar.
            showsGrabber: ![.expanded, .modelSetup, .permissions].contains(state.mode),
            onQuit: { state.quit() }
        ) {
            switch state.mode {
            case .expanded: AskBar(state: state)
            case .conversations: ConversationsScreen(state: state)
            case .answer(let thread):
                AnswerView(state: state, thread: thread) { state.closeAnswer() }
            case .settings: SettingsScreen(state: state)
            case .modelSetup: ModelSetupScreen(state: state)
            case .permissions: PermissionsScreen(state: state)
            }
        }
    }

    private var collapseAction: (() -> Void)? {
        switch state.mode {
        case .settings: { state.closeSettings() }
        case .expanded, .conversations, .answer, .modelSetup, .permissions: nil
        }
    }

    /// Pulling to the right leaves a reopened chat for the list, and the list for home.
    private var backAction: (() -> Void)? {
        switch state.mode {
        case .conversations: { state.closeConversations() }
        case .answer(let thread):
            thread.isResumed ? { state.closeAnswer() } : nil
        case .expanded, .settings, .modelSetup, .permissions: nil
        }
    }
}
