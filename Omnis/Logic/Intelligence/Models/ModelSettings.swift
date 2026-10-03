import Foundation
import Security

/// Where answers and summaries come from.
enum ModelProvider: String, CaseIterable, Identifiable, Codable {
    /// Apple Foundation Models on device: private, free, offline, small context window.
    case appleOnDevice
    /// Apple Foundation Models on Private Cloud Compute: larger context and reasoning,
    /// still private, needs a network connection and has a daily quota.
    case applePrivateCloud
    case anthropic
    case openAI

    var id: Self { self }

    /// The providers offered in Settings. Omnis runs on Apple Foundation Models for now; the
    /// Claude and OpenAI adapters stay in the project but aren't exposed.
    static let selectable: [ModelProvider] = [.appleOnDevice, .applePrivateCloud]

    var displayName: String {
        switch self {
        case .appleOnDevice: String(localized: "Apple Intelligence (On Device)")
        case .applePrivateCloud: String(localized: "Apple Intelligence (Private Cloud)")
        case .anthropic: String(localized: "Claude")
        case .openAI: String(localized: "OpenAI")
        }
    }

    /// Providers that need the user's own API key.
    var needsAPIKey: Bool { self == .anthropic || self == .openAI }
}

/// The user's model choice and per-provider options, persisted in user defaults. API keys
/// live in the Keychain, never in defaults.
@Observable
final class ModelSettings {
    static let anthropicModels: [(id: String, name: String)] = [
        ("claude-opus-5", "Claude Opus 5"),
        ("claude-sonnet-5", "Claude Sonnet 5"),
        ("claude-haiku-4-5", "Claude Haiku 4.5")
    ]

    var provider: ModelProvider {
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
    }
    var anthropicModel: String {
        didSet { defaults.set(anthropicModel, forKey: Keys.anthropicModel) }
    }
    /// Free-form so newly released OpenAI models can be used without an app update.
    var openAIModel: String {
        didSet { defaults.set(openAIModel, forKey: Keys.openAIModel) }
    }

    // Context sources, chosen from the live bar's more menu. All on by default.

    /// Transcribe (and record) the microphone during sessions.
    var useMicrophone: Bool {
        didSet { defaults.set(useMicrophone, forKey: Keys.useMicrophone) }
    }
    /// Transcribe (and record) the Mac's audio output (call participants, videos).
    var useSystemAudio: Bool {
        didSet { defaults.set(useSystemAudio, forKey: Keys.useSystemAudio) }
    }
    /// Let answers look at the screen when a question is about it.
    var useScreen: Bool {
        didSet { defaults.set(useScreen, forKey: Keys.useScreen) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A choice that's no longer offered (e.g. a cloud provider) falls back to on device.
        let saved = defaults.string(forKey: Keys.provider).flatMap(ModelProvider.init)
        provider = saved.flatMap { ModelProvider.selectable.contains($0) ? $0 : nil } ?? .appleOnDevice
        anthropicModel = defaults.string(forKey: Keys.anthropicModel) ?? Self.anthropicModels[0].id
        openAIModel = defaults.string(forKey: Keys.openAIModel) ?? "gpt-5"
        useMicrophone = defaults.object(forKey: Keys.useMicrophone) as? Bool ?? true
        useSystemAudio = defaults.object(forKey: Keys.useSystemAudio) as? Bool ?? true
        useScreen = defaults.object(forKey: Keys.useScreen) as? Bool ?? true
    }

    func apiKey(for provider: ModelProvider) -> String? {
        Keychain.read(account: provider.rawValue)
    }

    func setAPIKey(_ key: String, for provider: ModelProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(account: provider.rawValue)
        } else {
            Keychain.write(trimmed, account: provider.rawValue)
        }
    }

    private enum Keys {
        static let provider = "model.provider"
        static let anthropicModel = "model.anthropic.id"
        static let openAIModel = "model.openai.id"
        static let useMicrophone = "context.microphone"
        static let useSystemAudio = "context.systemAudio"
        static let useScreen = "context.screen"
    }
}

/// Minimal generic-password storage for provider API keys.
private enum Keychain {
    private static let service = "\(Bundle.main.bundleIdentifier ?? "Omnis").api-keys"

    private static func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func read(account: String) -> String? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account: account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func delete(account: String) {
        SecItemDelete(query(account: account) as CFDictionary)
    }
}
