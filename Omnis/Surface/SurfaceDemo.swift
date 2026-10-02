import SwiftUI

// Temporary content that proves the surface host morphs between a capsule and a rounded rectangle.

@Observable
final class DemoState {
    enum Mode { case compact, expanded }

    var mode: Mode = .compact
    var text = ""
}

struct SurfaceDemo: View {
    let state: DemoState

    var body: some View {
        SurfaceHost(
            id: state.mode,
            onCollapse: state.mode == .expanded ? { state.mode = .compact } : nil,
            onExpand: state.mode == .compact ? { state.mode = .expanded } : nil
        ) {
            switch state.mode {
            case .compact: compact
            case .expanded: DemoAskBar(state: state)
            }
        }
    }

    private var compact: some View {
        HStack(spacing: 4) {
            SurfaceButton("square.and.pencil") { state.mode = .expanded }
            SurfaceButton("list.bullet") {}
            SurfaceButton("play.fill", style: .prominent) {}
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
    }
}

/// A text field with buttons. While the text fits on one line it's a 72 pt capsule row;
/// once it wraps, the field moves above the buttons.
private struct DemoAskBar: View {
    @Bindable var state: DemoState

    @Environment(SurfaceState.self) private var surface: SurfaceState?
    @FocusState private var fieldFocused: Bool
    @State private var isMultiline = false
    @State private var lineHeight: CGFloat = 0
    @State private var textHeight: CGFloat = 0

    var body: some View {
        AskBarLayout(isMultiline: isMultiline) {
            TextField("Ask anything", text: $state.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(.white)
                .lineLimit(1...10)
                .focused($fieldFocused)
                .onSubmit(send)
            SurfaceButton("ellipsis") {}
            SurfaceButton("list.bullet") {}
            SurfaceButton("arrow.up", style: .prominent, action: send)
        }
        .padding(20)
        .background(alignment: .topLeading) { lineProbe }
        .onAppear {
            surface?.makeKey?()
            fieldFocused = true
        }
    }

    /// Hidden text laid out at the one-line field width, used to decide whether the text wraps.
    private var lineProbe: some View {
        ZStack(alignment: .topLeading) {
            Text(" ")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { lineHeight = $0; updateLayout() }
            Text(state.text.isEmpty ? " " : state.text)
                .frame(width: AskBarLayout.singleLineProbeWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0; updateLayout() }
        }
        .font(.body)
        .hidden()
    }

    private func updateLayout() {
        let wraps = textHeight > lineHeight + 1
        guard wraps != isMultiline else { return }
        withAnimation(SurfaceMotion.content) { isMultiline = wraps }
    }

    private func send() {
        state.text = ""
        state.mode = .compact
    }
}

/// Lays out [field, ellipsis, list, send] either in one row or with the field above the buttons.
/// One custom layout (rather than switching stacks) keeps the text field's identity and focus.
private struct AskBarLayout: Layout {
    var isMultiline: Bool

    static let width: CGFloat = 320          // 360 pt surface minus 20 pt padding each side
    static let buttonSize: CGFloat = 32
    static let rowSpacing: CGFloat = 6       // between the field and buttons on one line
    static let multilineSpacing: CGFloat = 4 // between the trailing buttons below the field
    static let fieldToButtons: CGFloat = 16  // vertical gap below the field when multiline
    static var singleLineFieldWidth: CGFloat { width - 3 * buttonSize - 3 * rowSpacing }
    /// Slightly narrower than the field, so the layout switches before the field itself wraps.
    static var singleLineProbeWidth: CGFloat { singleLineFieldWidth - 6 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 4 else { return .zero }
        let field = fieldSize(subviews)
        let height = isMultiline
            ? field.height + Self.fieldToButtons + Self.buttonSize
            : max(field.height, Self.buttonSize)
        return CGSize(width: Self.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 4 else { return }
        let field = fieldSize(subviews)
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

    private func fieldSize(_ subviews: Subviews) -> CGSize {
        let width = isMultiline ? Self.width : Self.singleLineFieldWidth
        let height = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: height)
    }
}
