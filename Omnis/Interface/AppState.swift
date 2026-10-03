import SwiftUI

/// Drives which screen the surface shows, and owns the data and intelligence services behind
/// them.
@Observable
final class AppState {
    enum Mode: Hashable {
        case compact, expanded, sessions, sessionsCompact
        case session(Session), sessionCompact(Session)
        case live, liveCompact, liveTranscript
        case answer(AnswerThread), answerCompact(AnswerThread), liveAsk, liveAnswer(AnswerThread)
        /// Settings, opened from any more menu; remembers the screen to return to.
        indirect case settings(Mode)
    }
    enum SessionsTab { case sessions, conversations }
    enum DetailTab { case summary, transcript, chats }

    var mode: Mode = .compact {
        didSet {
            // A thread that's been left (not just compacted, or covered by settings) stops answering.
            if let old = oldValue.thread, old !== mode.thread { old.cancel() }
            // Playback belongs to session detail (and its compact bar); leaving it stops.
            switch mode {
            case .session, .sessionCompact: break
            default: player.unload()
            }
        }
    }
    var text = ""
    var sessionsTab: SessionsTab = .sessions
    var detailTab: DetailTab = .summary

    // MARK: Services

    let store: SessionStore
    let settings: ModelSettings
    let recorder: LiveRecorder
    let transcriber: LiveTranscriber
    let player = SessionPlayer()
    /// The audio folder for the session being recorded.
    @ObservationIgnored private var recordingFolder: String?
    /// The questions asked during the session being recorded, saved with it.
    @ObservationIgnored private var liveChats: [SessionChat] = []
    let resolver: ModelResolver
    let index: SessionIndex
    let ask: AskService
    let processor: SessionProcessor

    init(store: SessionStore = SessionStore(), settings: ModelSettings = ModelSettings()) {
        self.store = store
        self.settings = settings
        let recorder = LiveRecorder()
        self.recorder = recorder
        transcriber = LiveTranscriber(recorder: recorder)
        resolver = ModelResolver(settings: settings)
        index = SessionIndex(store: store)
        ask = AskService(resolver: resolver, builder: ContextBuilder(index: index), settings: settings)
        processor = SessionProcessor(store: store, index: index, resolver: resolver)
        // Notes for the summary are written as the session records, so it's ready soon after.
        recorder.onLinesChanged = { [processor] lines in processor.liveTranscriptChanged(lines) }

        // Finish anything left from a previous launch, and bring older indexes up to date.
        Task { [processor, index] in
            await processor.processPending()
            index.reindexIfNeeded()
        }
    }

    // MARK: Sessions list

    /// Select mode and its selection, and the row being renamed.
    var isSelecting = false
    var selection: Set<UUID> = []
    var renamingID: UUID?

    func items(for tab: SessionsTab) -> [Session] {
        let all = tab == .sessions ? store.sessions : store.chats
        guard isFiltering, let filteredItems else { return all }
        return filteredItems
    }

    // MARK: Sessions filter

    /// The filter field replaces the bottom toolbar while it's open.
    var isFiltering = false
    /// Natural-language query, matched by meaning against titles, summaries and transcripts.
    var filterQuery = "" {
        didSet { if filterQuery != oldValue { scheduleFilter() } }
    }
    /// Matches for the current query and tab, best first; nil shows everything.
    private(set) var filteredItems: [Session]?
    /// The on-device model is still matching by meaning; the list shows instant matches meanwhile.
    private(set) var isRefiningFilter = false
    @ObservationIgnored private var filterTask: Task<Void, Never>?

    func startFiltering() {
        isSelecting = false
        selection.removeAll()
        renamingID = nil
        isFiltering = true
    }

    func stopFiltering() {
        filterTask?.cancel()
        isFiltering = false
        isRefiningFilter = false
        filterQuery = ""
        filteredItems = nil
    }

    /// Re-runs the filter now, e.g. after switching tabs or changing the list: instant matches
    /// right away, then the on-device model's matches by meaning.
    func applyFilter() {
        filterTask?.cancel()
        let query = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFiltering, !query.isEmpty else {
            filteredItems = nil
            isRefiningFilter = false
            return
        }
        let tab = sessionsTab
        let all = tab == .sessions ? store.sessions : store.chats
        filteredItems = index.filter(all, matching: query)
        isRefiningFilter = true
        filterTask = Task { [weak self, index] in
            let refined = await index.refine(all, matching: query)
            guard let self, !Task.isCancelled else { return }
            // Only if nothing changed while the model was reading.
            guard self.isFiltering, self.sessionsTab == tab,
                  self.filterQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            if let refined { self.filteredItems = refined }
            self.isRefiningFilter = false
        }
    }

    /// Waits for a pause in typing so the search doesn't run on every keystroke.
    private func scheduleFilter() {
        filterTask?.cancel()
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.applyFilter()
        }
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
        if isFiltering { applyFilter() }
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
        if isFiltering { applyFilter() }
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
        let folder = AudioStorage.makeFolder()
        recordingFolder = folder
        liveChats = []
        transcriber.setSource(.microphone, on: settings.useMicrophone)
        transcriber.setSource(.system, on: settings.useSystemAudio)
        transcriber.start(recordingTo: AudioStorage.url(for: folder))
        processor.liveSessionStarted()
        setOrbShape(.square)
        mode = compact ? .liveCompact : .live
    }

    // MARK: Context sources

    /// Whether sessions hear the microphone; applies right away to a session in progress.
    var usesMicrophone: Bool {
        get { settings.useMicrophone }
        set {
            settings.useMicrophone = newValue
            transcriber.setSource(.microphone, on: newValue)
        }
    }

    /// Whether sessions hear the Mac's audio output; applies right away to a session in progress.
    var usesSystemAudio: Bool {
        get { settings.useSystemAudio }
        set {
            settings.useSystemAudio = newValue
            transcriber.setSource(.system, on: newValue)
        }
    }

    /// Whether answers may look at the screen.
    var usesScreen: Bool {
        get { settings.useScreen }
        set { settings.useScreen = newValue }
    }

    /// Paused shows the small lit circle; recording shows the square.
    func togglePause() {
        isPaused.toggle()
        recorder.setPaused(isPaused)
        transcriber.setPaused(isPaused)
        setOrbShape(isPaused ? .circle : .square)
    }

    /// Stops recording, lets the last words finish transcribing, saves the session, then titles,
    /// summarizes and indexes it in the background.
    func endSession() {
        isPaused = false
        setOrbShape(.dots)
        mode = .compact
        // Load the model while the last words finish transcribing.
        processor.prepareForSummary()
        Task {
            await transcriber.stop()
            let notes = await processor.finishLiveNotes()
            saveRecording(liveNotes: notes)
        }
    }

    /// Saves the recording and summarizes it, picking up from any notes written while it recorded.
    private func saveRecording(liveNotes: LiveNotes? = nil) {
        let folder = recordingFolder
        recordingFolder = nil
        let chats = liveChats
        liveChats = []
        guard let recording = recorder.stop(), !recording.lines.isEmpty else {
            // Nothing was said, so nothing is saved, audio included.
            if let folder { AudioStorage.delete(folder) }
            return
        }
        let session = store.createSession(
            startedAt: recording.startedAt,
            lines: recording.lines,
            audioFolder: folder,
            chats: chats
        )
        Task { [processor] in await processor.process(session, liveNotes: liveNotes) }
    }

    /// Keeps an answered turn from a live thread, so it's saved in the session's Chats.
    func recordLiveTurn(chatID: UUID, question: String, answer: String) {
        guard let startedAt = recorder.startedAt else { return }
        let turn = SessionChat.Turn(question: question, answer: answer, offset: Date.now.timeIntervalSince(startedAt))
        if let index = liveChats.firstIndex(where: { $0.id == chatID }) {
            liveChats[index].turns.append(turn)
        } else {
            liveChats.append(SessionChat(id: chatID, turns: [turn]))
        }
    }

    /// The live transcript to answer from, while a session is recording.
    var liveContext: (startedAt: Date, lines: [LiveLine])? {
        recorder.startedAt.map { ($0, recorder.transcriptSoFar) }
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
        // A saved chat reopens as the conversation itself, ready for a follow-up.
        if session.kind == .chat {
            mode = .answer(AnswerThread(state: self, resuming: session))
            return
        }
        detailTab = .summary
        mode = .session(session)
    }

    /// Quits the app. A session that's still recording is saved first; its summary and index
    /// are finished on the next launch.
    func quit() {
        // Save what's been transcribed so far (including words still in progress) right away;
        // there's no time to wait for the speech model to finish.
        if recorder.isRecording {
            transcriber.finishWriting()  // finalize the audio files so they play
            saveRecording()
        }
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

    /// Opens a thread answering `question`, from the main ask or during a live session.
    func openAnswer(_ question: String, live: Bool) {
        let thread = AnswerThread(state: self, question: question, isLive: live)
        mode = live ? .liveAnswer(thread) : .answer(thread)
    }

    /// Leaving an answer returns to the Chats list if that's where it was opened, otherwise to
    /// a clean, empty expanded ask.
    func closeAnswer() {
        if mode.thread?.isResumed == true {
            sessionsTab = .conversations
            showSessions()
            return
        }
        text = ""
        mode = .expanded
    }

    /// Leaving sessions always lands on a clean, empty expanded ask.
    func closeSessions() {
        stopFiltering()
        text = ""
        mode = .expanded
    }
}

extension AppState.Mode {
    /// The question thread this screen shows, if any.
    var thread: AnswerThread? {
        switch self {
        case .answer(let thread), .answerCompact(let thread), .liveAnswer(let thread): thread
        case .settings(let previous): previous.thread
        default: nil
        }
    }
}
