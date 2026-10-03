import SwiftUI

// MARK: - More menu

/// The ellipsis menu used everywhere. For now it holds only Settings…; screen-specific items
/// can be passed in later (`MoreMenu(state:) { … }`), and appear above a divider.
struct MoreMenu<Items: View>: View {
    let state: AppState
    let items: Items?

    init(state: AppState, @ViewBuilder items: () -> Items) {
        self.state = state
        self.items = items()
    }

    var body: some View {
        SurfaceMenuButton("ellipsis") {
            if let items {
                items
                Divider()
            }
            Button("Settings…", systemImage: "gearshape") { state.openSettings() }
        }
    }
}

extension MoreMenu where Items == EmptyView {
    init(state: AppState) {
        self.state = state
        self.items = nil
    }
}
