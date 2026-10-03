import SwiftUI

/// A text field with buttons. While the text fits on one line it's a 72 pt capsule row;
/// once it wraps, the field moves above the buttons.
struct AskBar: View {
    /// The main ask, or asking about the live session (which swaps in the transcript button,
    /// and shows compose selected while empty: tapping it returns to the session).
    enum Context { case main, liveSession }

    @Bindable var state: AppState
    var context: Context = .main

    private var placeholder: String {
        context == .main ? "Ask anything" : "Ask About This Session"
    }

    @Environment(SurfaceState.self) private var surface: SurfaceState?
    @FocusState private var fieldFocused: Bool
    @State private var isMultiline = false
    @State private var lineHeight: CGFloat = 0
    @State private var textHeight: CGFloat = 0

    private static let fieldFont = Font.system(size: 15)
    private static let fieldLineHeight = AttributedString.LineHeight.exact(points: 18)

    var body: some View {
        AskBarLayout(isMultiline: isMultiline) {
            TextField(placeholder, text: $state.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Self.fieldFont)
                .environment(\.lineHeight, Self.fieldLineHeight)
                .foregroundStyle(.white)
                .lineLimit(1...10)
                .focused($fieldFocused)
                .onSubmit(send)
            MoreMenu(state: state, showsQuit: true) {
                // Captures the window under the surface along with the question.
                Toggle("Screen Context", systemImage: "macwindow", isOn: Bindable(state.settings).includeScreen)
            }
            switch context {
            case .main:
                SurfaceButton("list.bullet") { state.showSessions() }
                SurfaceButton(isEmpty ? "play.fill" : "arrow.up", style: .prominent) {
                    if isEmpty { state.startSession(compact: false) } else { send() }
                }
            case .liveSession:
                SurfaceButton("quote.bubble") { state.mode = .liveTranscript }
                SurfaceButton(isEmpty ? "square.and.pencil" : "arrow.up", style: .prominent) {
                    if isEmpty { state.mode = .live } else { send() }
                }
            }
        }
        .padding(isMultiline ? 20 : 18)
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
        .font(Self.fieldFont)
        .environment(\.lineHeight, Self.fieldLineHeight)
        .hidden()
    }

    private func updateLayout() {
        // Wait for both measurements; otherwise the first one alone can briefly read as wrapped.
        guard lineHeight > 0, textHeight > 0 else { return }
        let wraps = textHeight > lineHeight + 1
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
        state.mode = context == .main ? .answer(question) : .liveAnswer(question)
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
