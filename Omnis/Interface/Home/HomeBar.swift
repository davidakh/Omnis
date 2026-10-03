import SwiftUI

/// The main 48 pt capsule: compose, sessions, start a live session.
struct HomeBar: View {
    let state: AppState

    var body: some View {
        HStack(spacing: 4) {
            SurfaceButton("square.and.pencil") { state.mode = .expanded }
            SurfaceButton("list.bullet") { state.showSessions() }
            SurfaceButton("play.fill", style: .prominent) { state.startSession(compact: true) }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
    }
}
