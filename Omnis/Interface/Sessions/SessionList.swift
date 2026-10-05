import SwiftUI

/// Scrollable list of sessions or chats. Rows tint on hover; in select mode they toggle
/// selection instead of opening. Right-click for Select, Rename, Share and Delete.
struct SessionList: View {
    @Bindable var state: AppState

    var body: some View {
        FadingScroll {
            LazyVStack(spacing: 2) {
                if state.isFiltering, state.filteredItems?.isEmpty == true {
                    // While the model is still matching by meaning, results may yet appear.
                    Group {
                        if state.isRefiningFilter {
                            ShimmerText(String(localized: "Searching"))
                        } else {
                            Text("No matches")
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                ForEach(state.items(for: state.sessionsTab)) { session in
                    SessionRow(state: state, session: session)
                }
            }
            // Rows inset their text by 10 pt so the hover tint has room; this keeps the text
            // aligned with the toolbars.
            .padding(.horizontal, -10)
            .animation(.smooth(duration: 0.25), value: state.items(for: state.sessionsTab).map(\.id))
        }
        .id(state.sessionsTab)  // each tab starts at the top
    }
}

private struct SessionRow: View {
    @Bindable var state: AppState
    let session: Session

    @Environment(SurfaceState.self) private var surface: SurfaceState?
    @State private var isHovered = false
    @State private var draftTitle = ""
    @FocusState private var renameFocused: Bool

    private var isSelected: Bool { state.selection.contains(session.id) }
    private var isRenaming: Bool { state.renamingID == session.id }

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
                            draftTitle = session.title
                            surface?.makeKey?()
                            renameFocused = true
                        }
                } else {
                    Text(session.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
                Text(session.time)
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
                state.toggleSelection(session.id)
            } else {
                state.openSession(session)
            }
        }
        .contextMenu {
            Button("Select", systemImage: "checkmark.circle") { state.startSelecting(with: session.id) }
            Button("Rename", systemImage: "pencil") { state.renamingID = session.id }
            ShareLink(item: session.shareText, subject: Text(session.title)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { state.delete([session.id]) }
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
        state.rename(session.id, to: draftTitle)
    }
}
