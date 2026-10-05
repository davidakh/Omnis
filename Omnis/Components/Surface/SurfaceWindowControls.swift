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

    static let height: CGFloat = 32
    /// Space between the capsule and the top of the surface.
    static let gap: CGFloat = 8

    var body: some View {
        HStack(spacing: 7) {
            Dot(color: Self.red, glyph: .system("xmark"), action: onQuit)
            Dot(color: Self.yellow, glyph: .system("minus"), action: onMinimize)
            Dot(color: Self.green, glyph: .custom("expand"), action: onExpand)
        }
        .padding(.horizontal, 9)
        .frame(height: Self.height)
        .background {
            // #000000 at 96%, over the glass so its edge still catches the light.
            Capsule().fill(.black.opacity(0.96))
                .padding(0.5)
                .background { GlassSurface(radius: Self.height / 2) }
        }
        .clipShape(Capsule())
    }

    private static let red = Color(.red)
    private static let yellow = Color(.yellow)
    private static let green = Color(.green)

    private struct Dot: View {
        enum Glyph {
            case system(String)
            /// A custom symbol from `Assets.xcassets/Symbol`.
            case custom(String)
        }

        let color: Color
        let glyph: Glyph
        let action: (() -> Void)?

        private static let size: CGFloat = 16

        private var isEnabled: Bool { action != nil }

        var body: some View {
            Button { action?() } label: {
                image
                    .foregroundStyle(.black.opacity(0.52))
                    .blendMode(.plusDarker)
                    .frame(width: Self.size, height: Self.size)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            // Tinted glass that reacts to the pointer and to presses; dimmed and inert when the
            // surface is already at that size.
            .glassEffect(glass, in: Circle())
            .opacity(isEnabled ? 1 : 0.4)
            .disabled(!isEnabled)
            .animation(.smooth(duration: 0.2), value: isEnabled)
        }

        private var glass: Glass {
            isEnabled ? .regular.tint(color).interactive() : .regular.tint(color.opacity(0.5))
        }

        @ViewBuilder
        private var image: some View {
            switch glyph {
            case .system(let name): Image(systemName: name).font(.system(size: 8, weight: .black))
            case .custom(let name): Image(name).font(.system(size: 8, weight: .black))
            }
        }
    }
}
