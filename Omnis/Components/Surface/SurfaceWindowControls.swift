import SwiftUI

/// Quit, minimize and expand, as three colored dots on a small glass capsule that floats
/// centered above the surface while the pointer is over it. Minimize and expand dim when the
/// surface is already at that size.
struct SurfaceWindowControls: View {
    var onQuit: () -> Void
    /// Nil when the surface is already at its smallest.
    var onMinimize: (() -> Void)?
    /// Nil when the surface is already at its largest.
    var onExpand: (() -> Void)?

    static let height: CGFloat = 44
    /// Space between the capsule and the top of the surface.
    static let gap: CGFloat = 8

    var body: some View {
        HStack(spacing: 9) {
            Dot(color: Self.red, glyph: .system("xmark"), action: onQuit)
            Dot(color: Self.yellow, glyph: .system("minus"), action: onMinimize)
            Dot(color: Self.green, glyph: .asset("Expand"), action: onExpand)
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .background {
            Capsule().fill(SurfaceShade.gradient)
                .padding(0.5)
                .background { GlassSurface(radius: Self.height / 2) }
        }
        .clipShape(Capsule())
    }

    private static let red = Color(red: 0.89, green: 0.37, blue: 0.30)
    private static let yellow = Color(red: 0.95, green: 0.82, blue: 0.29)
    private static let green = Color(red: 0.45, green: 0.78, blue: 0.38)

    private struct Dot: View {
        enum Glyph {
            case system(String)
            case asset(String)
        }

        let color: Color
        let glyph: Glyph
        let action: (() -> Void)?

        @State private var isHovered = false
        private static let size: CGFloat = 22

        var body: some View {
            Button { action?() } label: {
                Circle()
                    .fill(color)
                    .overlay {
                        // The glyph is the dot's own color, darkened, like the mockup.
                        image
                            .foregroundStyle(.black.opacity(0.4))
                    }
                    .frame(width: Self.size, height: Self.size)
                    .opacity(action == nil ? 0.35 : 1)
                    .brightness(isHovered && action != nil ? 0.06 : 0)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(action == nil)
            .onHover { isHovered = $0 }
            .animation(.smooth(duration: 0.2), value: action == nil)
        }

        @ViewBuilder
        private var image: some View {
            switch glyph {
            case .system(let name):
                Image(systemName: name)
                    .font(.system(size: 10, weight: .bold))
            case .asset(let name):
                Image(name)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 9, height: 9)
            }
        }
    }
}
