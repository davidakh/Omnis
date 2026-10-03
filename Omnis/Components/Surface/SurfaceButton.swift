import SwiftUI

/// The circular 32 pt glass icon button used throughout the surface.
struct SurfaceButton: View {
    enum Style {
        /// Clear interactive glass with a white symbol.
        case standard
        /// White-tinted interactive glass with a black symbol, for the primary action.
        case prominent
    }

    let symbol: String
    var style: Style = .standard
    let action: () -> Void

    init(_ symbol: String, style: Style = .standard, action: @escaping () -> Void) {
        self.symbol = symbol
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: style == .prominent ? .semibold : .medium))
                .foregroundStyle(style == .prominent ? .black : .white)
                .contentTransition(.symbolEffect(.replace))
                .animation(.smooth(duration: 0.25), value: symbol)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(glass, in: Circle())
    }

    private var glass: Glass {
        switch style {
        case .standard: .clear.interactive()
        case .prominent: .regular.tint(.white).interactive()
        }
    }
}

/// A `SurfaceButton` look-alike that opens the share sheet for `item`.
struct SurfaceShareButton: View {
    let item: String
    var subject: String? = nil

    var body: some View {
        ShareLink(item: item, subject: subject.map { Text($0) }) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: Circle())
    }
}
