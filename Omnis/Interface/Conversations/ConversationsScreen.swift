import SwiftUI

/// 340×400: the saved chats, research or scheduled list scrolling behind its two toolbars,
/// with a tab bar between them. Also the sidebar beside an open chat (see `ChatSplitView`):
/// narrower, without the back button, and with just the tab bar along the bottom.
struct ConversationsScreen: View {
    let state: AppState
    var isSidebar = false

    /// The tab bar's margin from the sidebar's sides and bottom.
    static let sidebarTabInset: CGFloat = 8
    /// The 216 pt tab bar with `sidebarTabInset` either side.
    static let sidebarWidth: CGFloat = 216 + sidebarTabInset * 2

    var body: some View {
        ZStack {
            // Full-height list that scrolls behind both toolbars; each tab starts at the top.
            Group {
                switch state.chatsTab {
                case .conversations: ConversationList(state: state)
                case .research: EmptyTabList(message: "No research yet")
                case .scheduled: EmptyTabList(message: "Nothing scheduled yet")
                }
            }
            .id(state.chatsTab)
            .transition(.blurReplace)
            toolbars
        }
        .frame(width: isSidebar ? Self.sidebarWidth : 340, height: 400)
        .animation(SurfaceMotion.content, value: state.chatsTab)
    }

    private var toolbars: some View {
        VStack(spacing: 0) {
            // Top toolbar: back (not in the sidebar), centered title, new.
            ZStack {
                ConversationsTitle(tab: state.chatsTab)
                HStack {
                    if !isSidebar {
                        SurfaceButton("chevron.left") { state.closeConversations() }
                    }
                    Spacer()
                    NewButton(state: state)
                }
            }

            Spacer(minLength: 0)

            // Bottom toolbar: select, the tabs, filter. In select mode: select (prominent), a
            // glass selection count, and delete. While filtering: the search field.
            if state.isFiltering {
                ConversationsFilterBar(state: state)
                    .transition(.blurReplace)
            } else {
                standardToolbar
                    .transition(.blurReplace)
            }
        }
        .padding(20)
        .animation(SurfaceMotion.content, value: state.isFiltering)
    }

    /// Select and filter work on chats; research and scheduled have nothing to select or
    /// search yet.
    private var listActionsEnabled: Bool { state.chatsTab == .conversations }

    private var tabBar: some View {
        SurfaceTabBar(
            tabs: [
                .init(value: .conversations, title: "Chats", symbol: "bubble.left.and.bubble.right"),
                .init(value: .research, title: "Research", symbol: "brain.filled.head.profile"),
                .init(value: .scheduled, title: "Scheduled", symbol: "clock")
            ],
            selection: Bindable(state).chatsTab
        )
    }

    @ViewBuilder
    private var standardToolbar: some View {
        if isSidebar {
            // Just the tabs, in a row their own height, reaching past the toolbars' 20 pt
            // padding so they sit `sidebarTabInset` from the sides and bottom. Selecting and
            // filtering are in the full list.
            tabBar
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .padding(.horizontal, Self.sidebarTabInset - 20)
                .padding(.bottom, Self.sidebarTabInset - 20)
        } else {
            fullToolbar
        }
    }

    private var fullToolbar: some View {
        HStack(spacing: 0) {
            SurfaceButton("checklist", style: state.isSelecting ? .prominent : .standard) {
                state.toggleSelecting()
            }
            .disabled(!listActionsEnabled)
            .opacity(listActionsEnabled ? 1 : 0.4)
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
                tabBar
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
                    .disabled(!listActionsEnabled)
                    .opacity(listActionsEnabled ? 1 : 0.4)
                    .transition(.blurReplace)
            }
        }
        // The 52 pt tab bar overflows the 32 pt toolbar row, centered on it.
        .frame(height: 32)
        .animation(SurfaceMotion.content, value: state.isSelecting)
        .animation(.smooth(duration: 0.2), value: state.selection.count)
    }
}

/// 72 pt capsule: back, the selected tab's title, and new.
struct ConversationsCompactBar: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 8) {
            SurfaceButton("chevron.left") { state.closeConversations() }
            ConversationsTitle(tab: state.chatsTab)
                .frame(maxWidth: .infinity)
            NewButton(state: state)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(width: 256, height: 72)
    }
}

/// Starts something new in the selected tab: a blank chat on Chats. Research and scheduled
/// tasks can't be created yet, so it's dimmed on those tabs.
private struct NewButton: View {
    let state: AppState

    private var isEnabled: Bool { state.chatsTab == .conversations }

    var body: some View {
        SurfaceButton("square.and.pencil") {
            switch state.chatsTab {
            case .conversations: state.newChat()
            case .research, .scheduled: break
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.smooth(duration: 0.2), value: isEnabled)
    }
}

/// The filter: a field like the chat's, and a button that closes it and shows everything again.
private struct ConversationsFilterBar: View {
    @Bindable var state: AppState

    @Environment(SurfaceState.self) private var surface: SurfaceState?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField("Search Chats", text: $state.filterQuery, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(.white)
                .lineLimit(1...3)
                .focused($fieldFocused)
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

private struct ConversationsTitle: View {
    let tab: AppState.ChatsTab

    private var title: LocalizedStringKey {
        switch tab {
        case .conversations: "Chats"
        case .research: "Research"
        case .scheduled: "Scheduled"
        }
    }

    var body: some View {
        Text(title)
            .contentTransition(.numericText())
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .toolbarTitleShadow()
    }
}

// MARK: - Lists

/// A tab that isn't built yet (research, scheduled): shows where its items will go.
private struct EmptyTabList: View {
    let message: LocalizedStringKey

    var body: some View {
        FadingScroll {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }
    }
}

/// Scrollable list of saved chats. Rows tint on hover; in select mode they toggle selection
/// instead of opening. Right-click for Select, Rename, Share and Delete.
private struct ConversationList: View {
    @Bindable var state: AppState

    var body: some View {
        let chats = state.visibleChats
        FadingScroll {
            LazyVStack(spacing: 2) {
                if chats.isEmpty {
                    Text(state.isFiltering ? "No matches" : "No chats yet")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                ForEach(chats) { chat in
                    ConversationRow(state: state, chat: chat)
                }
            }
            // Rows inset their text by 10 pt so the hover tint has room; this keeps the text
            // aligned with the toolbars.
            .padding(.horizontal, -10)
            .animation(.smooth(duration: 0.25), value: chats.map(\.id))
        }
    }
}

private struct ConversationRow: View {
    @Bindable var state: AppState
    let chat: Chat

    @Environment(SurfaceState.self) private var surface: SurfaceState?
    @State private var isHovered = false
    @State private var draftTitle = ""
    @FocusState private var renameFocused: Bool

    private var isSelected: Bool { state.selection.contains(chat.id) }
    /// The chat open beside the sidebar.
    private var isCurrent: Bool { !state.isSelecting && state.mode.thread?.chatID == chat.id }
    private var isRenaming: Bool { state.renamingID == chat.id }

    var body: some View {
        HStack(spacing: 10) {
            if state.isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.4))
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Title", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                        .focused($renameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { state.renamingID = nil }
                        .onAppear {
                            draftTitle = chat.title
                            surface?.makeKey?()
                            renameFocused = true
                        }
                } else {
                    Text(chat.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
                Text(chat.time)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            .white.opacity(isSelected || isCurrent ? 0.12 : (isHovered ? 0.06 : 0)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture {
            guard !isRenaming else { return }
            if state.isSelecting {
                state.toggleSelection(chat.id)
            } else {
                state.openChat(chat)
            }
        }
        .contextMenu {
            Button("Select", systemImage: "checkmark.circle") { state.startSelecting(with: chat.id) }
            Button("Rename", systemImage: "pencil") { state.renamingID = chat.id }
            ShareLink(item: chat.shareText, subject: Text(chat.title)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { state.delete([chat.id]) }
        }
        .animation(.smooth(duration: 0.15), value: isHovered)
        .animation(.smooth(duration: 0.2), value: isSelected)
        .animation(.smooth(duration: 0.25), value: state.isSelecting)
        .onChange(of: isRenaming) { _, renaming in
            if !renaming { renameFocused = false }
        }
        .onChange(of: renameFocused) { _, focused in
            // Clicking away commits the rename.
            if !focused, isRenaming { commitRename() }
        }
    }

    private func commitRename() {
        state.rename(chat.id, to: draftTitle)
    }
}
