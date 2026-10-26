import SwiftUI

/// An open chat, always with the chats list (`ConversationsScreen`, tab bar and all) beside it
/// as a sidebar. Picking another chat in the sidebar swaps only the chat pane.
struct ChatSplitView: View {
    @Bindable var state: AppState
    let thread: AnswerThread
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ConversationsScreen(state: state, isSidebar: true)
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 1)
                .padding(.vertical, 20)
            ZStack {
                AnswerView(state: state, thread: thread, onBack: onBack)
                    .id(thread)
                    .transition(.blurReplace)
            }
            .animation(SurfaceMotion.content, value: thread)
        }
    }
}
