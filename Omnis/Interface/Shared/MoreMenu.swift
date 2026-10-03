import SwiftUI

// MARK: - More menu

/// The ellipsis menu used everywhere. It always holds Settings…; screen-specific items can be
/// passed in (`MoreMenu(state:) { … }`) and appear above a divider, and `showsQuit` adds
/// Quit Omnis at the bottom.
struct MoreMenu<Items: View>: View {
    let state: AppState
    let items: Items?
    var showsQuit = false

    init(state: AppState, showsQuit: Bool = false, @ViewBuilder items: () -> Items) {
        self.state = state
        self.showsQuit = showsQuit
        self.items = items()
    }

    var body: some View {
        SurfaceMenuButton("ellipsis") {
            Group {
                if let items {
                    items
                    Divider()
                }
                Button("Settings", systemImage: "gearshape") { state.openSettings() }
                if showsQuit {
                    Button("Quit", systemImage: "power") { state.quit() }
                        .keyboardShortcut("q")
                }
            }
            // macOS menus show titles only by default; show each item's symbol too.
            .labelStyle(.titleAndIcon)
        }
    }
}

extension MoreMenu where Items == EmptyView {
    init(state: AppState, showsQuit: Bool = false) {
        self.state = state
        self.showsQuit = showsQuit
        self.items = nil
    }
}
