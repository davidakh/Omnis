import SwiftUI

/// Quit, minimize and expand, as three colored dots on a small glass capsule that floats
/// centered above the surface while the pointer is near its top. Minimize and expand dim when
/// the surface is already at that size.
struct SurfaceWindowControls: View {
    var onQuit: () -> Void
    /// Nil when the surface is already at its smallest.
    var onMinimize: (() -> Void)?
    /// Nil when the surface is already at its largest.
    var onExpand: (() -> Void)?

    static let height: CGFloat = 32
    /// Space between the capsule and the top of the surface.
    static let gap: CGFloat = 6
    /// The band along the top of the glass where the pointer brings the controls out.
    static let revealBand: CGFloat = 44

    var body: some View {
        HStack(spacing: 4) {
            Dot(color: .red, glyph: .system("xmark"), action: onQuit)
            Dot(color: .yellow, glyph: .system("minus"), action: onMinimize)
            Dot(color: .green, glyph: .custom("expand"), action: onExpand)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background {
            // #000000 at 96%, over the glass so its edge still catches the light.
            Capsule().fill(.black.opacity(0.96))
                .padding(0.5)
                .background { GlassSurface(radius: Self.height / 2) }
        }
        .clipShape(Capsule())
    }

    /// Each dot's fill (saturated, lightening slightly toward the bottom) and the thin darker rim around it.
    struct DotColor {
        let top: Color
        let bottom: Color
        let rim: Color

        static let red = DotColor(top: Color(hex: 0xE5493A), bottom: Color(hex: 0xF0685A), rim: Color(hex: 0xB14206))
        static let yellow = DotColor(top: Color(hex: 0xE6A620), bottom: Color(hex: 0xF2BE3A), rim: Color(hex: 0x933E06))
        static let green = DotColor(top: Color(hex: 0x4FAE2E), bottom: Color(hex: 0x6CC24A), rim: Color(hex: 0x32620F))

        var fill: LinearGradient {
            LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
        }
    }

    private struct Dot: View {
        enum Glyph {
            case system(String)
            /// A custom symbol from `Assets.xcassets/Symbol`.
            case custom(String)
        }

        let color: DotColor
        let glyph: Glyph
        let action: (() -> Void)?

        private static let size: CGFloat = 16

        private var isEnabled: Bool { action != nil }

        var body: some View {
            Button { action?() } label: {
                image
                    .foregroundStyle(.black.opacity(0.32))
                    .blendMode(.plusDarker)
                    .frame(width: Self.size, height: Self.size)
                    .background(Circle().fill(color.fill))
                    .overlay(Circle().strokeBorder(color.rim, lineWidth: 0.5))
                    .compositingGroup()
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            // Clear glass over the color, so the dot reacts to the pointer and to presses; dimmed
            // and inert when the surface is already at that size.
            .glassEffect(isEnabled ? .clear.interactive() : .clear, in: Circle())
            .opacity(isEnabled ? 1 : 0.4)
            .disabled(!isEnabled)
            .animation(.smooth(duration: 0.2), value: isEnabled)
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

private extension Color {
    /// A color from a hex value like 0xDF9581.
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
