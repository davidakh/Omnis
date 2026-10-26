import SwiftUI

/// A text field with buttons. It widens as soon as anything is typed; while the text fits on
/// one line it's a capsule row, and once it wraps the field moves above the buttons.
struct AskBar: View {
    @Bindable var state: AppState

    @Environment(SurfaceState.self) private var surface: SurfaceState?
    @Environment(\.surfaceGlassSize) private var glassSize
    @FocusState private var fieldFocused: Bool
    @State private var isMultiline = false
    @State private var width = AskBarLayout.minWidth
    @State private var textWidth: CGFloat = 0

    private static let fieldFont = Font.system(size: 15)
    private static let fieldLineHeight = AttributedString.LineHeight.exact(points: 18)
    /// Room past the measured text, so the bar wraps before the field itself wraps.
    private static let probeSlack: CGFloat = 6
    private static let horizontalPadding: CGFloat = 20

    /// Where the buttons sit: inside the glass as it springs between widths, so they move
    /// with its edges. The bar still reports `width`, which is what the glass springs to.
    private var displayWidth: CGFloat {
        guard let glassSize else { return width }
        // Unclamped above, so the buttons ride the spring's overshoot too; never so narrow
        // that the field disappears (as when the glass is still small, mid-swap).
        return max(glassSize.width - Self.horizontalPadding * 2, AskBarLayout.buttonsWidth + 40)
    }

    var body: some View {
        AskBarLayout(isMultiline: isMultiline, width: width, displayWidth: displayWidth) {
            TextField("Ask anything", text: $state.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Self.fieldFont)
                .environment(\.lineHeight, Self.fieldLineHeight)
                .foregroundStyle(.white)
                .lineLimit(1...10)
                .focused($fieldFocused)
                .onSubmit(send)
            MoreMenu(state: state, showsQuit: true)
            SurfaceButton("list.bullet") { state.showConversations() }
            SurfaceButton("arrow.up", style: .prominent) { send() }
        }
        // Only the vertical padding changes, so the bar keeps its width as the text wraps.
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, isMultiline ? 20 : 18)
        .background(alignment: .topLeading) { lineProbe }
        .onAppear {
            surface?.makeKey?()
            fieldFocused = true
        }
    }

    /// Hidden, unwrapped copy of the text, measuring how wide one line of it is.
    private var lineProbe: some View {
        Text(state.text.isEmpty ? " " : state.text)
            .font(Self.fieldFont)
            .environment(\.lineHeight, Self.fieldLineHeight)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0; updateLayout() }
            .hidden()
    }

    /// Widens the bar to its widest as soon as anything is typed (and back when it's cleared);
    /// text too long for that one line, or a typed line break, wraps.
    private func updateLayout() {
        let fieldWidth = textWidth + Self.probeSlack
        let wraps = state.text.contains("\n") || fieldWidth > AskBarLayout.singleLineFieldWidth(for: AskBarLayout.maxWidth)
        let newWidth = state.text.isEmpty ? AskBarLayout.minWidth : AskBarLayout.maxWidth
        // Not animated here: the glass springs to the new width, and the buttons follow it.
        width = newWidth
        guard wraps != isMultiline else { return }
        withAnimation(SurfaceMotion.content) { isMultiline = wraps }
    }

    private var isEmpty: Bool {
        state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard !isEmpty else { return }
        let question = state.text.trimmingCharacters(in: .whitespacesAndNewlines)
        state.text = ""
        state.openAnswer(question)
    }
}

/// Lays out [field, ellipsis, list, send] either in one row or with the field above the buttons.
/// One custom layout (rather than switching stacks) keeps the text field's identity and focus.
private struct AskBarLayout: Layout {
    var isMultiline: Bool
    /// The content width the bar reports (inside the 20 pt padding): `minWidth` when empty,
    /// else `maxWidth`.
    var width: CGFloat
    /// The width the field and buttons are laid out in, centered in `width`: the glass's
    /// current width while it springs there.
    var displayWidth: CGFloat

    static let minWidth: CGFloat = 260       // the empty bar: a 300 pt surface
    static let maxWidth: CGFloat = 360       // once anything is typed: a 480 pt surface
    static let buttonSize: CGFloat = 32
    static let rowSpacing: CGFloat = 6       // between the field and buttons on one line
    static let multilineSpacing: CGFloat = 4 // between the trailing buttons below the field
    static let fieldToButtons: CGFloat = 16  // vertical gap below the field when multiline
    /// The three buttons beside the field on one line, with their spacing.
    static var buttonsWidth: CGFloat { 3 * buttonSize + 3 * rowSpacing }
    static func singleLineFieldWidth(for width: CGFloat) -> CGFloat { width - buttonsWidth }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 4 else { return .zero }
        let field = fieldSize(subviews)
        let height = isMultiline
            ? field.height + Self.fieldToButtons + Self.buttonSize
            : max(field.height, Self.buttonSize)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in reported: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        // The glass is centered on the bar, so its current width is too.
        let bounds = reported.insetBy(dx: (reported.width - displayWidth) / 2, dy: 0)
        let field = fieldSize(subviews, width: displayWidth)
        let button = ProposedViewSize(width: Self.buttonSize, height: Self.buttonSize)
        let (ellipsis, list, send) = (subviews[1], subviews[2], subviews[3])

        if isMultiline {
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(field))
            let rowY = bounds.maxY - Self.buttonSize / 2
            ellipsis.place(at: CGPoint(x: bounds.minX, y: rowY), anchor: .leading, proposal: button)
            send.place(at: CGPoint(x: bounds.maxX, y: rowY), anchor: .trailing, proposal: button)
            list.place(
                at: CGPoint(x: bounds.maxX - Self.buttonSize - Self.multilineSpacing, y: rowY),
                anchor: .trailing, proposal: button
            )
        } else {
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(field))
            let step = Self.buttonSize + Self.rowSpacing
            send.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: button)
            list.place(at: CGPoint(x: bounds.maxX - step, y: bounds.midY), anchor: .trailing, proposal: button)
            ellipsis.place(at: CGPoint(x: bounds.maxX - step * 2, y: bounds.midY), anchor: .trailing, proposal: button)
        }
    }

    private func fieldSize(_ subviews: Subviews, width: CGFloat? = nil) -> CGSize {
        let width = width ?? self.width
        let fieldWidth = isMultiline ? width : Self.singleLineFieldWidth(for: width)
        let height = subviews[0].sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil)).height
        return CGSize(width: fieldWidth, height: height)
    }
}
