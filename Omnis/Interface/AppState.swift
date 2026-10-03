import SwiftUI

/// Drives which screen the surface shows, plus the mock data behind them.
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

    /// Sessions list: the two tabs' items, select mode and its selection, and the row
    /// being renamed.
    var sessions = Session.mockSessions
    var chats = Session.mockChats
    var isSelecting = false
    var selection: Set<UUID> = []
    var renamingID: UUID?

    func items(for tab: SessionsTab) -> [Session] {
        tab == .sessions ? sessions : chats
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
        sessions.removeAll { ids.contains($0.id) }
        chats.removeAll { ids.contains($0.id) }
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
        if let index = sessions.firstIndex(where: { $0.id == id }) { sessions[index].title = trimmed }
        if let index = chats.firstIndex(where: { $0.id == id }) { chats[index].title = trimmed }
    }

    /// Live session. The orb lives here (not in a view) so it stays continuous while the
    /// surface swaps between the compact and expanded live layouts.
    var isPaused = false
    var orb = OrbAnimation(epoch: .now, epochPhase: 0)

    /// Starts recording: the orb morphs to its square. Opens in the live layout matching
    /// the height of the screen the play button was on.
    func startSession(compact: Bool) {
        isPaused = false
        setOrbShape(.square)
        mode = compact ? .liveCompact : .live
    }

    /// Paused shows the small lit circle; recording shows the square.
    func togglePause() {
        isPaused.toggle()
        setOrbShape(isPaused ? .circle : .square)
    }

    func endSession() {
        isPaused = false
        setOrbShape(.dots)
        mode = .compact
    }

    /// Morphs the orb to `shape` (the shader crossfades over `OrbAnimation.morphDuration`).
    func setOrbShape(_ shape: OrbShape) {
        guard orb.shape != shape else { return }
        orb.previousShape = orb.shape
        orb.shape = shape
        orb.shapeStart = .now
    }

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
