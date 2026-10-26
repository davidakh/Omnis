import FoundationModels
import SwiftUI

/// Drives which screen the surface shows, and owns the data and intelligence services behind
/// them.
@Observable
final class AppState {
    enum Mode: Hashable {
        case expanded
        /// The saved chats list.
        case conversations
        case answer(AnswerThread)
        /// Settings, opened from any more menu; remembers the screen to return to.
        indirect case settings(Mode)
        /// Downloading a model, before Omnis can be used.
        case modelSetup
        /// Asking for Screen Recording, once, after the model.
        case permissions
    }

    var mode: Mode = .expanded {
        didSet {
            // A thread that's been left (not just covered by settings) stops answering.
            if let old = oldValue.thread, old !== mode.thread { old.cancel() }
        }
    }
    var text = ""

    // MARK: Services

    let store: ChatStore
    let settings: ModelSettings
    /// Downloaded models (Bonsai), which answer chats.
    let models = LocalModelStore()
    let resolver: ModelResolver
    let ask: AskService

    init(store: ChatStore = ChatStore(), settings: ModelSettings = ModelSettings()) {
        self.store = store
        self.settings = settings
        resolver = ModelResolver(settings: settings)
        ask = AskService(resolver: resolver, builder: ContextBuilder(), settings: settings)
        // Omnis runs on a downloaded model, so one has to be here before anything else.
        if let chosen = settings.localModel, models.isInstalled(chosen) {
            // Ready.
        } else if let installed = LocalModelOption.all.first(where: models.isInstalled) {
            // Downloaded but never chosen (e.g. setup was quit just as it finished): use it.
            settings.localModelID = installed.id
            settings.provider = .local
        } else {
            mode = .modelSetup
        }
        if mode == .expanded, !hasSeenPermissions { mode = .permissions }

        // Load the downloaded model now, off the main thread, so the first question doesn't
        // wait on reading its weights and compiling its GPU kernels.
        warmUpLocalModel()
    }

    // MARK: Conversations list

    /// The list's tabs: projects, the saved chats, or scheduled chats.
    enum ChatsTab { case projects, conversations, scheduled }
    var chatsTab: ChatsTab = .conversations {
        didSet {
            guard chatsTab != oldValue else { return }
            // Selecting, renaming and filtering belong to the tab they started in.
            isSelecting = false
            selection.removeAll()
            renamingID = nil
            stopFiltering()
        }
    }

    /// Select mode and its selection, and the row being renamed.
    var isSelecting = false
    var selection: Set<UUID> = []
    var renamingID: UUID?

    /// The filter field replaces the bottom toolbar while it's open.
    var isFiltering = false
    /// Matched against titles, questions and answers.
    var filterQuery = ""

    /// The chats the list shows: all of them, or those matching the filter.
    var visibleChats: [Chat] {
        let query = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFiltering, !query.isEmpty else { return store.chats }
        return store.chats.filter { $0.matches(query) }
    }

    func startFiltering() {
        isSelecting = false
        selection.removeAll()
        renamingID = nil
        isFiltering = true
    }

    func stopFiltering() {
        isFiltering = false
        filterQuery = ""
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
    }

    // MARK: Context sources

    /// Whether answers may look at the screen.
    var usesScreen: Bool {
        get { settings.useScreen }
        set { settings.useScreen = newValue }
    }

    /// Whether answers may search the web.
    var usesWeb: Bool {
        get { settings.useWeb }
        set { settings.useWeb = newValue }
    }

    // MARK: Navigation

    func showConversations() {
        isSelecting = false
        selection.removeAll()
        renamingID = nil
        mode = .conversations
    }

    /// Leaving the list always lands on a clean, empty expanded ask.
    func closeConversations() {
        stopFiltering()
        text = ""
        mode = .expanded
    }

    /// Starts over on a clean, empty expanded ask.
    func newChat() {
        text = ""
        mode = .expanded
    }

    /// Reopens a saved chat as the conversation itself, ready for a follow-up.
    func openChat(_ chat: Chat) {
        mode = .answer(AnswerThread(state: self, resuming: chat))
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Answers with a downloaded model from now on, and leaves setup if that's where it was.
    func useDownloadedModel(_ model: LocalModelOption) {
        settings.localModelID = model.id
        settings.provider = .local
        if mode == .modelSetup { mode = hasSeenPermissions ? .expanded : .permissions }
        warmUpLocalModel()
    }

    private static let permissionsKey = "permissions.seen"
    private var hasSeenPermissions: Bool { UserDefaults.standard.bool(forKey: Self.permissionsKey) }

    /// Leaves the permission steps for Omnis; they aren't shown again.
    func finishPermissions() {
        UserDefaults.standard.set(true, forKey: Self.permissionsKey)
        if mode == .permissions { mode = .expanded }
    }

    /// Loads the chosen downloaded model in the background and primes a session with it, and
    /// readies Apple's on-device model, which decides what each question needs.
    private func warmUpLocalModel() {
        if let onDevice = try? resolver.onDevice() {
            LanguageModelSession(model: onDevice.model).prewarm()
        }
        guard settings.provider == .local, let model = try? resolver.local() else { return }
        LanguageModelSession(model: model.model).prewarm()
    }

    func openSettings() {
        if case .settings = mode { return }
        mode = .settings(mode)
    }

    func closeSettings() {
        if case .settings(let previous) = mode { mode = previous }
    }

    /// Opens a thread answering `question`.
    func openAnswer(_ question: String) {
        mode = .answer(AnswerThread(state: self, question: question))
    }

    /// Leaving an answer returns to the list if that's where it was opened, otherwise to a
    /// clean, empty expanded ask.
    func closeAnswer() {
        if mode.thread?.isResumed == true {
            showConversations()
            return
        }
        text = ""
        mode = .expanded
    }
}

extension AppState.Mode {
    /// The question thread this screen shows, if any.
    var thread: AnswerThread? {
        switch self {
        case .answer(let thread): thread
        case .settings(let previous): previous.thread
        default: nil
        }
    }
}
