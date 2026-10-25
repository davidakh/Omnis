import SwiftUI

/// Routes `AppState.mode` to its screen inside the surface host, and decides what
/// collapsing and expanding do from each one.
struct RootView: View {
    let state: AppState

    var body: some View {
        SurfaceHost(
            id: state.mode,
            onCollapse: collapseAction,
            onExpand: expandAction,
            onBack: nil,
            // No grabber on the main compact bar.
            showsGrabber: ![.compact, .modelSetup, .permissions].contains(state.mode),
            onQuit: { state.quit() },
            onMinimize: minimizeAction,
            onMaximize: maximizeAction
        ) {
            switch state.mode {
            case .compact: HomeBar(state: state)
            case .expanded: AskBar(state: state)
            case .answer(let thread):
                AnswerView(state: state, thread: thread) { state.closeAnswer() }
            case .answerCompact(let thread):
                AnswerCompactBar(state: state, thread: thread) { state.closeAnswer() }
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
        // Pulling a chat down tucks it into its compact bar rather than closing it.
        case .answer(let thread): { state.mode = .answerCompact(thread) }
        case .answerCompact: nil
        case .settings: { state.closeSettings() }
        case .modelSetup, .permissions: nil
        }
    }

    /// Window controls: the current screen's compact bar, or nil when it's already showing.
    private var minimizeAction: (() -> Void)? {
        switch state.mode {
        case .expanded: { state.mode = .compact }
        case .answer(let thread): { state.mode = .answerCompact(thread) }
        case .settings: {
            state.closeSettings()
            state.mode = Self.compactForm(of: state.mode) ?? state.mode
        }
        case .compact, .answerCompact, .modelSetup, .permissions: nil
        }
    }

    /// Window controls: the current screen's full view, or nil when it's already showing.
    private var maximizeAction: (() -> Void)? { expandAction }

    /// The compact bar for a full screen, for leaving settings straight to it.
    private static func compactForm(of mode: AppState.Mode) -> AppState.Mode? {
        switch mode {
        case .expanded: .compact
        case .answer(let thread): .answerCompact(thread)
        default: nil
        }
    }

    private var expandAction: (() -> Void)? {
        switch state.mode {
        case .compact: { state.mode = .expanded }
        case .answerCompact(let thread): { state.mode = .answer(thread) }
        case .expanded, .answer, .settings, .modelSetup, .permissions: nil
        }
    }
}
