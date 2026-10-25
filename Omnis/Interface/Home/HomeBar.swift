import SwiftUI

/// The main 48 pt capsule: compose.
struct HomeBar: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 4) {
            SurfaceButton("square.and.pencil") { state.mode = .expanded }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
    }
}
