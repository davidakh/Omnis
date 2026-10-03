import SwiftUI

/// Full-height scroll view whose content fades out under the top and bottom toolbars,
/// and that can be pulled past its top to collapse the surface.
struct FadingScroll<Content: View>: View {
    /// Where the scroll view starts, e.g. `.bottom` for a transcript that grows downward.
    var anchor: UnitPoint? = nil
    /// The surface height. With the default toolbars (20 pt padding + 32 pt bar; a bottom tab
    /// bar spills 10 pt further), content starts below / ends above them, and fades beneath.
    var height: CGFloat = 380
    var topClear: CGFloat = 64
    /// Room left below the content (less when there's no bottom toolbar).
    var bottomClear: CGFloat = 76
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            content()
                .padding(.horizontal, 16)
                .padding(.top, topClear)
                .padding(.bottom, bottomClear)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(anchor)
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: (topClear + 8) / height),
                    .init(color: .black, location: (height - bottomClear - 12) / height),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .surfaceScrollable(startsAtTop: anchor == nil || anchor == .top)
    }
}
