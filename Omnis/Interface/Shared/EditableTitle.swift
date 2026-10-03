import SwiftUI

/// A toolbar title that turns into a text field while `isEditing`, for Rename. Return or
/// clicking away commits; Escape cancels.
struct EditableTitle: View {
    let title: String
    @Binding var isEditing: Bool
    var font: Font = .system(size: 15, weight: .semibold)
    let commit: (String) -> Void

    @Environment(SurfaceState.self) private var surface: SurfaceState?
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField("Title", text: $draft)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit(finish)
                    .onExitCommand { isEditing = false }
                    .onAppear {
                        draft = title
                        surface?.makeKey?()
                        focused = true
                    }
            } else {
                Text(title)
            }
        }
        .font(font)
        .foregroundStyle(.white)
        .lineLimit(1)
        .onChange(of: focused) { _, isFocused in
            // Clicking away commits; after Escape, editing has already ended.
            if !isFocused, isEditing { finish() }
        }
    }

    private func finish() {
        commit(draft)
        isEditing = false
    }
}
