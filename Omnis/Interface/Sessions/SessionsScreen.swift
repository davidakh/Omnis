import SwiftUI

/// 340×400: the sessions / chats list scrolling behind its two toolbars.
struct SessionsScreen: View {
    let state: AppState

    var body: some View {
        ZStack {
            // Full-height list that scrolls behind both toolbars.
            SessionList(state: state)
            toolbars
        }
        .frame(width: 340, height: 400)
    }

    private var toolbars: some View {
        VStack(spacing: 0) {
            // Top toolbar: back, centered title, more.
            ZStack {
                SessionsTitle(state: state)
                HStack {
                    SurfaceButton("chevron.left") { state.closeSessions() }
                    Spacer()
                    MoreMenu(state: state)
                }
            }

            Spacer(minLength: 0)

            // Bottom toolbar: select, tabs, filter. In select mode: select (prominent), a glass
            // selection count, and delete. While filtering: the search field.
            if state.isFiltering {
                SessionsFilterBar(state: state)
                    .transition(.blurReplace)
            } else {
                standardToolbar
                    .transition(.blurReplace)
            }
        }
        .padding(20)
        .animation(SurfaceMotion.content, value: state.isFiltering)
        .onChange(of: state.sessionsTab) { state.applyFilter() }
    }

    private var standardToolbar: some View {
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
                        .init(value: .sessions, title: "Sessions", symbol: "inset.filled.rectangle.and.person"),
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
                SurfaceButton("line.3.horizontal.decrease") { state.startFiltering() }
                    .transition(.blurReplace)
            }
        }
        // The 52 pt tab bar overflows the 32 pt toolbar row, centered on it.
        .frame(height: 32)
        .animation(SurfaceMotion.content, value: state.isSelecting)
        .animation(.smooth(duration: 0.2), value: state.selection.count)
    }
}

/// The filter: a field like the chat's, matched by meaning ("pricing meetings last week"), and
/// a button that closes it and shows everything again.
private struct SessionsFilterBar: View {
    @Bindable var state: AppState

    @Environment(SurfaceState.self) private var surface: SurfaceState?
    @FocusState private var fieldFocused: Bool

    private var placeholder: String {
        state.sessionsTab == .sessions
            ? String(localized: "Search Sessions")
            : String(localized: "Search Chats")
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(placeholder, text: $state.filterQuery, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(.white)
                .lineLimit(1...3)
                .focused($fieldFocused)
                .onSubmit { state.applyFilter() }
                .onExitCommand { state.stopFiltering() }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .glassEffect(.clear.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            SurfaceButton("xmark") { state.stopFiltering() }
        }
        .frame(minHeight: 32, alignment: .bottom)
        .onAppear {
            surface?.makeKey?()
            fieldFocused = true
        }
    }
}

/// 72 pt capsule: back, title, filter.
struct SessionsCompactBar: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 0) {
            SurfaceButton("chevron.left") { state.closeSessions() }
            Spacer(minLength: 0)
            SessionsTitle(state: state)
            Spacer(minLength: 0)
            SurfaceButton("line.3.horizontal.decrease") {
                state.mode = .sessions
                state.startFiltering()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(width: 256, height: 72)
    }
}

private struct SessionsTitle: View {
    let state: AppState
    
    var body: some View {
        Text(state.sessionsTab == .sessions ? "Sessions" : "Chats")
            .contentTransition(.numericText())
            .transition(.blurReplace)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .toolbarTitleShadow()
    }
}
