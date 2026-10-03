import SwiftUI

/// 320×380: the sessions / chats list scrolling behind its two toolbars.
struct SessionsScreen: View {
    let state: AppState

    var body: some View {
        ZStack {
            // Full-height list that scrolls behind both toolbars.
            SessionList(state: state)
            toolbars
        }
        .frame(width: 320, height: 380)
    }

    private var toolbars: some View {
        VStack(spacing: 0) {
            // Top toolbar: back, centered title, more.
            ZStack {
                SessionsTitle()
                HStack {
                    SurfaceButton("chevron.left") { state.closeSessions() }
                    Spacer()
                    MoreMenu(state: state)
                }
            }

            Spacer(minLength: 0)

            // Bottom toolbar: select, tabs, filter. In select mode: select (prominent), a glass
            // selection count, and delete.
            HStack(spacing: 0) {
                SurfaceButton("checklist", style: state.isSelecting ? .prominent : .standard) {
                    state.toggleSelecting()
                }
                Spacer(minLength: 0)
                if state.isSelecting {
                    Text(state.selection.count == 1 ? "1 Selection" : "\(state.selection.count) Selections")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .glassEffect(.clear, in: Capsule())
                        .transition(.blurReplace)
                } else {
                    SurfaceTabBar(
                        tabs: [
                            .init(value: .sessions, title: "Sessions", symbol: "calendar"),
                            .init(value: .conversations, title: "Chats", symbol: "bubble.left.and.bubble.right")
                        ],
                        selection: Bindable(state).sessionsTab
                    )
                    .zIndex(1)  // the lifted pill floats above the neighbouring buttons
                    .transition(.blurReplace)
                }
                Spacer(minLength: 0)
                if state.isSelecting {
                    SurfaceButton("trash") { state.deleteSelection() }
                        .disabled(state.selection.isEmpty)
                        .opacity(state.selection.isEmpty ? 0.4 : 1)
                        .transition(.blurReplace)
                } else {
                    SurfaceButton("line.3.horizontal.decrease") {}
                        .transition(.blurReplace)
                }
            }
            // The 52 pt tab bar overflows the 32 pt toolbar row, centered on it.
            .frame(height: 32)
            .animation(SurfaceMotion.content, value: state.isSelecting)
            .animation(.smooth(duration: 0.2), value: state.selection.count)
        }
        .padding(20)
    }
}

/// 72 pt capsule: back, title, filter.
struct SessionsCompactBar: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 0) {
            SurfaceButton("chevron.left") { state.closeSessions() }
            Spacer(minLength: 0)
            SessionsTitle()
            Spacer(minLength: 0)
            SurfaceButton("line.3.horizontal.decrease") {}
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(width: 256, height: 72)
    }
}

private struct SessionsTitle: View {
    var body: some View {
        Text("Sessions")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
    }
}
