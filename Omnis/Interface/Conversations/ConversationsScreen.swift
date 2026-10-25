import SwiftUI

/// 340×400: the saved chats list scrolling behind its two toolbars.
struct ConversationsScreen: View {
    let state: AppState

    var body: some View {
        ZStack {
            // Full-height list that scrolls behind both toolbars.
            ConversationList(state: state)
            toolbars
        }
        .frame(width: 340, height: 400)
    }

    private var toolbars: some View {
        VStack(spacing: 0) {
            // Top toolbar: back, centered title, more.
            ZStack {
                ConversationsTitle()
                HStack {
                    SurfaceButton("chevron.left") { state.closeConversations() }
                    Spacer()
                    MoreMenu(state: state)
                }
            }

            Spacer(minLength: 0)

            // Bottom toolbar: select, new chat, filter. In select mode: select (prominent), a
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
                SurfaceButton("square.and.pencil") { state.closeConversations() }
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
        .frame(height: 32)
        .animation(SurfaceMotion.content, value: state.isSelecting)
        .animation(.smooth(duration: 0.2), value: state.selection.count)
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

/// 72 pt capsule: back, title, filter.
struct ConversationsCompactBar: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 0) {
            SurfaceButton("chevron.left") { state.closeConversations() }
            Spacer(minLength: 0)
            ConversationsTitle()
            Spacer(minLength: 0)
            SurfaceButton("line.3.horizontal.decrease") {
                state.mode = .conversations
                state.startFiltering()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 20)
        .frame(width: 256, height: 72)
    }
}

private struct ConversationsTitle: View {
    var body: some View {
        Text("Chats")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .toolbarTitleShadow()
    }
}

// MARK: - List

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
            .white.opacity(isSelected ? 0.12 : (isHovered ? 0.06 : 0)),
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
