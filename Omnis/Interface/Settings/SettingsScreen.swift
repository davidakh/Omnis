import SwiftUI

// MARK: - Settings

/// Settings inside the glass: 512×612, blank for now apart from the back button and title.
/// Back (or pulling down) returns to where it was opened from.
struct SettingsScreen: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Settings")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                HStack {
                    SurfaceButton("chevron.left") { state.closeSettings() }
                    Spacer()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 512, height: 612)
    }
}
