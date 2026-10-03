import SwiftUI

/// The session's recording and its points of interest, pinned under the top toolbar.
///
/// Three states: collapsed (title, current section, sections and play), playing (adds the
/// progress bar and skip controls), and the sections list (each section with its start time;
/// tapping one plays from there). Sessions recorded before audio was saved show only their
/// sections.
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

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                header
                if hasStarted {
                    ProgressBar(progress: player.progress) { player.seek(to: $0 * player.duration) }
                }
                if hasStarted && !showsSections {
                    controls
                }
            }
            .padding(14)

            if showsSections {
                sectionList
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(SurfaceMotion.content, value: hasStarted)
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
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.2), value: subtitle)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            if !sections.isEmpty {
                SurfaceButton("list.bullet", style: showsSections ? .prominent : .standard) {
                    showsSections.toggle()
                }
            }
            // Play sits up here until playback starts; then it moves to the controls, except
            // while the sections list covers them.
            if hasAudio && (!hasStarted || showsSections) {
                SurfaceButton(isPlaying ? "pause.fill" : "play.fill") { player.togglePlayback() }
            }
        }
    }

    private var subtitle: String {
        if let currentSection { return currentSection.title }
        if hasStarted {
            return "\(SessionSection.format(player.currentTime)) / \(SessionSection.format(player.duration))"
        }
        return hasAudio ? SessionSection.format(player.duration) : String(localized: "Recording")
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 28) {
            SkipButton(symbol: "gobackward.15") { player.skip(by: -15) }
            SurfaceButton(isPlaying ? "pause.fill" : "play.fill") { player.togglePlayback() }
            SkipButton(symbol: "goforward.15") { player.skip(by: 15) }
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    // MARK: Sections

    private var sectionList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 {
                        Divider().overlay(.white.opacity(0.08))
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
        // Up to three rows show at once; more scroll.
        .frame(height: min(CGFloat(sections.count), 3) * SectionRow.height)
        .background(.black.opacity(0.25))
    }
}

/// The ±15 s buttons: bare symbols, as in the playing state.
private struct SkipButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
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
    }
}

/// A capsule track that fills with progress; click or drag to seek.
private struct ProgressBar: View {
    let progress: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.15))
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: max(6, geometry.size.width * progress))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    seek(min(max(value.location.x / geometry.size.width, 0), 1))
                }
            )
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.25), value: progress)
    }
}
