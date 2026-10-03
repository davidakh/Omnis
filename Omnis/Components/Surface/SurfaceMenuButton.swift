import SwiftUI

/// A `SurfaceButton` look-alike (32 pt clear interactive glass circle) that opens a menu.
struct SurfaceMenuButton<Items: View>: View {
    let symbol: String
    @ViewBuilder let items: () -> Items

    init(_ symbol: String, @ViewBuilder items: @escaping () -> Items) {
        self.symbol = symbol
        self.items = items
    }

    var body: some View {
        Menu {
            items()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .glassEffect(.clear.interactive(), in: Circle())
    }
}
