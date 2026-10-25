import FoundationModels
import SwiftUI

/// Drives which screen the surface shows, and owns the intelligence services behind them.
@Observable
final class AppState {
    enum Mode: Hashable {
        case compact, expanded
        case answer(AnswerThread), answerCompact(AnswerThread)
        /// Settings, opened from any more menu; remembers the screen to return to.
        indirect case settings(Mode)
        /// Downloading a model, before Omnis can be used.
        case modelSetup
        /// Asking for Screen Recording, once, after the model.
        case permissions
    }

    var mode: Mode = .compact {
        didSet {
            // A thread that's been left (not just compacted, or covered by settings) stops answering.
            if let old = oldValue.thread, old !== mode.thread { old.cancel() }
        }
    }
    var text = ""

    // MARK: Services

    let settings: ModelSettings
    /// Downloaded models (Bonsai), which answer chats.
    let models = LocalModelStore()
    let resolver: ModelResolver
    let ask: AskService

    init(settings: ModelSettings = ModelSettings()) {
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
        if mode == .compact, !hasSeenPermissions { mode = .permissions }

        // Load the downloaded model now, off the main thread, so the first question doesn't
        // wait on reading its weights and compiling its GPU kernels.
        warmUpLocalModel()
    }

    // MARK: Context sources

    /// Whether answers may look at the screen.
    var usesScreen: Bool {
        get { settings.useScreen }
        set { settings.useScreen = newValue }
    }

    // MARK: Navigation

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// Answers with a downloaded model from now on, and leaves setup if that's where it was.
    func useDownloadedModel(_ model: LocalModelOption) {
        settings.localModelID = model.id
        settings.provider = .local
        if mode == .modelSetup { mode = hasSeenPermissions ? .compact : .permissions }
        warmUpLocalModel()
    }

    private static let permissionsKey = "permissions.seen"
    private var hasSeenPermissions: Bool { UserDefaults.standard.bool(forKey: Self.permissionsKey) }

    /// Leaves the permission steps for Omnis; they aren't shown again.
    func finishPermissions() {
        UserDefaults.standard.set(true, forKey: Self.permissionsKey)
        if mode == .permissions { mode = .compact }
    }

    /// Loads the chosen downloaded model in the background and primes a session with it.
    private func warmUpLocalModel() {
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

    /// Leaving an answer returns to a clean, empty expanded ask.
    func closeAnswer() {
        text = ""
        mode = .expanded
    }
}

extension AppState.Mode {
    /// The question thread this screen shows, if any.
    var thread: AnswerThread? {
        switch self {
        case .answer(let thread), .answerCompact(let thread): thread
        case .settings(let previous): previous.thread
        default: nil
        }
    }
}
