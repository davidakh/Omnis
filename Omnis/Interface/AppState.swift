import SwiftUI

/// Drives which screen the surface shows, and owns the data and intelligence services behind
/// them.
@Observable
final class AppState {
    enum Mode: Hashable {
        case compact, expanded, sessions, sessionsCompact
        case session(Session), sessionCompact(Session)
        case live, liveCompact, liveTranscript
        case answer(String), liveAsk, liveAnswer(String)
        /// Settings, opened from any more menu; remembers the screen to return to.
        indirect case settings(Mode)
    }
    enum SessionsTab { case sessions, conversations }
    enum DetailTab { case summary, transcript }

    var mode: Mode = .compact
    var text = ""
    var sessionsTab: SessionsTab = .sessions
    var detailTab: DetailTab = .summary

    // MARK: Services

    let store: SessionStore
    let settings: ModelSettings
    let recorder = LiveRecorder()
    let resolver: ModelResolver
    let index: SessionIndex
    let ask: AskService
    let processor: SessionProcessor

    init(store: SessionStore = SessionStore(), settings: ModelSettings = ModelSettings()) {
        self.store = store
        self.settings = settings
        resolver = ModelResolver(settings: settings)
        index = SessionIndex(store: store)
        ask = AskService(resolver: resolver, builder: ContextBuilder(index: index), settings: settings)
        processor = SessionProcessor(store: store, index: index, resolver: resolver)

        // Finish anything left from a previous launch (and index seeded sessions).
        Task { [processor] in await processor.processPending() }
    }

    // MARK: Sessions list

    /// Select mode and its selection, and the row being renamed.
    var isSelecting = false
    var selection: Set<UUID> = []
    var renamingID: UUID?

    func items(for tab: SessionsTab) -> [Session] {
        tab == .sessions ? store.sessions : store.chats
    }

    func toggleSelecting() {
        isSelecting.toggle()
        selection.removeAll()
        renamingID = nil
    }

    func startSelecting(with id: UUID) {
        isSelecting = true
        renamingID = nil
        selection = [id]
    }

    func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func delete(_ ids: Set<UUID>) {
        store.delete(ids)
        index.invalidate()
        selection.subtract(ids)
    }

    /// Deletes the selection and leaves select mode.
    func deleteSelection() {
        delete(selection)
        isSelecting = false
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { renamingID = nil }
        guard !trimmed.isEmpty else { return }
        store.rename(id, to: trimmed)
        index.invalidate()
    }

    // MARK: Live session

    /// The orb lives here (not in a view) so it stays continuous while the surface swaps
    /// between the compact and expanded live layouts.
    var isPaused = false
    var orb = OrbAnimation(epoch: .now, epochPhase: 0)

    /// Starts recording: the orb morphs to its square. Opens in the live layout matching
    /// the height of the screen the play button was on.
    func startSession(compact: Bool) {
        isPaused = false
        recorder.start()
        setOrbShape(.square)
        mode = compact ? .liveCompact : .live
    }

    /// Paused shows the small lit circle; recording shows the square.
    func togglePause() {
        isPaused.toggle()
        recorder.setPaused(isPaused)
        setOrbShape(isPaused ? .circle : .square)
    }

    /// Saves the session, then titles, summarizes and indexes it in the background.
    func endSession() {
        isPaused = false
        setOrbShape(.dots)
        mode = .compact
        guard let recording = recorder.stop(), !recording.lines.isEmpty else { return }
        let session = store.createSession(startedAt: recording.startedAt, lines: recording.lines)
        Task { [processor] in await processor.process(session) }
    }

    /// The live transcript to answer from, while a session is recording.
    var liveContext: (startedAt: Date, lines: [LiveLine])? {
        recorder.startedAt.map { ($0, recorder.lines) }
    }

    /// Morphs the orb to `shape` (the shader crossfades over `OrbAnimation.morphDuration`).
    func setOrbShape(_ shape: OrbShape) {
        guard orb.shape != shape else { return }
        orb.previousShape = orb.shape
        orb.shape = shape
        orb.shapeStart = .now
    }

    // MARK: Navigation

    func showSessions() {
        isSelecting = false
        selection.removeAll()
        renamingID = nil
        mode = .sessions
    }

    func openSession(_ session: Session) {
        detailTab = .summary
        mode = .session(session)
    }

    /// Quits the app. A session that's still recording is saved first; its summary and index
    /// are finished on the next launch.
    func quit() {
        if recorder.isRecording { endSession() }
        NSApplication.shared.terminate(nil)
    }

    func openSettings() {
        if case .settings = mode { return }
        mode = .settings(mode)
    }

    func closeSettings() {
        if case .settings(let previous) = mode { mode = previous }
    }

    /// Opens the ask bar for the live session, starting empty.
    func askAboutSession() {
        text = ""
        mode = .liveAsk
    }

    /// Leaving an answer returns to a clean, empty expanded ask.
    func closeAnswer() {
        text = ""
        mode = .expanded
    }

    /// Leaving sessions always lands on a clean, empty expanded ask.
    func closeSessions() {
        text = ""
        mode = .expanded
    }
}
