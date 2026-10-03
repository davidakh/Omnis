import SwiftUI

// MARK: - Live orb

/// The live session's orb: tap to end the session. Pausing is the button beside it.
struct LiveOrb: View {
    let state: AppState
    let diameter: CGFloat

    @State private var ended = false

    var body: some View {
        Button {
            guard !ended else { return }
            ended = true
            state.endSession()
        } label: {
            SurfaceOrb(animation: state.orb, diameter: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: Circle())
        .help(String(localized: "End Session"))
    }
}
