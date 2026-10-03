import SwiftUI

/// The session's recording and its points of interest, at the top of the summary.
///
/// One layout whether playing or not: the title, the current section, the sections button and
/// play (pause while playing). The sections button opens the list, each section with its start
/// time; tapping one plays from there. Sessions recorded before audio was saved show only their
/// sections. Changes blur in and out.
struct SessionPlayerCard: View {
    @Bindable var player: SessionPlayer
    let session: Session

    @State private var showsSections = false

    private var sections: [SessionSection] { session.sections }
    private var isLoaded: Bool { player.sessionID == session.id }
    private var hasAudio: Bool { isLoaded && player.isAvailable }
    private var hasStarted: Bool { isLoaded && player.hasStarted }
    private var isPlaying: Bool { isLoaded && player.isPlaying }

    /// The section playing now, or the first before playback starts.
    private var currentSection: SessionSection? {
        guard hasStarted else { return sections.first }
        return sections.last { $0.start <= player.currentTime } ?? sections.first
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(14)

            if showsSections {
                // Progress with a tick at each section, only while the sections are open.
                if hasAudio {
                    SectionProgressBar(
                        progress: player.progress,
                        markers: sections.dropFirst().map { player.duration > 0 ? $0.start / player.duration : 0 }
                    ) { player.seek(to: $0 * player.duration) }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.blurReplace)
                }
                sectionList
                    .transition(.blurReplace)
            }
        }
        .background(.ultraThinMaterial, in: shape)
        .clipShape(shape)
        .animation(SurfaceMotion.content, value: showsSections)
        .task(id: session.id) { await player.load(session) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                // Blurs from one section's title to the next as playback moves on.
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .id(subtitle)
                    .transition(.blurReplace)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(SurfaceMotion.content, value: subtitle)

            if !sections.isEmpty {
                CardButton(symbol: "list.bullet", style: showsSections ? .selected : .bare) {
                    showsSections.toggle()
                }
            }
            if hasAudio {
                CardButton(symbol: isPlaying ? "pause.fill" : "play.fill", style: .filled) { player.togglePlayback() }
            }
        }
    }

    private var subtitle: String {
        if let currentSection { return currentSection.title }
        return hasAudio ? SessionSection.format(player.duration) : String(localized: "Recording")
    }

    // MARK: Sections

    private var sectionList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 {
                        Divider().overlay(.white.opacity(0.05))
                    }
                    SectionRow(
                        section: section,
                        isCurrent: hasStarted && section == currentSection,
                        canPlay: hasAudio
                    ) {
                        player.play(from: section.start)
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .scrollIndicators(.hidden)
        // The scroll view would otherwise take rounded corners from the card around it; the
        // list's band runs straight across, only the card's own bottom corners are rounded.
        .scrollClipDisabled()
        .frame(height: min(CGFloat(sections.count), 3) * SectionRow.height)
        .frame(maxWidth: .infinity)
        .clipShape(Rectangle())
        .containerShape(Rectangle())
        .background(Rectangle().fill(.black.opacity(0.25)))
    }
}

/// The card's buttons: flat, not glass. Bare symbols for secondary actions, a gray circle for
/// play/pause, and a white circle for the sections button while its list is open.
private struct CardButton: View {
    enum Style { case bare, filled, selected }

    let symbol: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: style == .bare ? 17 : 15, weight: .semibold))
                .foregroundStyle(style == .selected ? .black : .white)
                // Play and pause swap with a blur.
                .contentTransition(.symbolEffect(.replace))
                .animation(SurfaceMotion.content, value: symbol)
                .frame(width: 32, height: 32)
                .background {
                    switch style {
                    case .bare: Color.clear
                    case .filled: Circle().fill(.white.opacity(0.12))
                    case .selected: Circle().fill(.white)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .animation(.smooth(duration: 0.2), value: style)
    }
}

private struct SectionRow: View {
    static let height: CGFloat = 38

    let section: SessionSection
    let isCurrent: Bool
    let canPlay: Bool
    let play: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack {
            Text(section.title)
                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(.white.opacity(isCurrent ? 1 : 0.85))
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(section.timestamp)
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(height: Self.height)
        .contentShape(Rectangle())
        .opacity(isHovered && canPlay ? 0.75 : 1)
        .onHover { isHovered = $0 }
        .onTapGesture { if canPlay { play() } }
        .animation(.smooth(duration: 0.15), value: isHovered)
        .animation(SurfaceMotion.content, value: isCurrent)
    }
}

/// A rounded track that fills with progress (the fill's leading edge runs straight, clipped by
/// the track) with a thin tick where each section starts. Click or drag to seek.
private struct SectionProgressBar: View {
    let progress: Double
    /// Where sections start, as fractions of the whole.
    let markers: [Double]
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.12))
                Rectangle()
                    .fill(.white.opacity(0.9))
                    .frame(width: width * min(max(progress, 0), 1))
                ForEach(markers, id: \.self) { marker in
                    Rectangle()
                        .fill(.white.opacity(0.18))
                        .frame(width: 2)
                        .offset(x: width * marker - 1)
                }
            }
            .clipShape(Capsule())
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    seek(min(max(value.location.x / width, 0), 1))
                }
            )
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.25), value: progress)
    }
}
