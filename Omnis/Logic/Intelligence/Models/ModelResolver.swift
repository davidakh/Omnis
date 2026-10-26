import Foundation
import FoundationModels
import OmnisModels
import Security

/// A model ready to prompt, plus what context building needs to know about it.
struct ResolvedModel {
    let provider: ModelProvider
    let model: any LanguageModel
    /// Tokens the prompt (context + question) may use, after reserving room for the
    /// instructions and the answer.
    let promptBudget: Int
    /// For estimating token counts from text before the prompt is assembled.
    let charactersPerToken: Double
    /// Loads the weights into memory (returns at once when they already are), and the name to
    /// show while it does. Only downloaded models need it.
    var load: (name: String, run: @Sendable () async throws -> Void)? = nil
    /// Tokens of context a chat answer reads. Smaller than `promptBudget` for downloaded models:
    /// the model has to read every prompt token before its first word, so a short, focused
    /// prompt answers far sooner. Summaries, written in the background, still get the full budget.
    var chatBudget: Int? = nil
    /// Words an answer may run to; answers are short, so this only stops a runaway reply.
    var maximumAnswerTokens: Int? = nil
    /// The longest side, in pixels, of a screenshot sent to the model. Image tokens grow with
    /// the area, and a downloaded model reads them all before its first word.
    var maximumImageDimension: Int? = nil
    /// The same model able to think before it answers, when it can. A downloaded model needs
    /// its own instance with thinking declared (it shares the loaded weights); cloud models
    /// take a reasoning level on each request. Nil for Apple's on-device model.
    var thinkingModel: (any LanguageModel)? = nil

    var answerBudget: Int { chatBudget ?? promptBudget }
    var canThink: Bool { thinkingModel != nil }

    var supportsVision: Bool { model.capabilities.contains(.vision) }
    var supportsGuidedGeneration: Bool { model.capabilities.contains(.guidedGeneration) }

    /// The on-device model can count tokens exactly; others are estimated.
    var isOnDevice: Bool { provider == .appleOnDevice }

    func estimatedTokens(_ text: String) -> Int {
        Int((Double(text.count) / charactersPerToken).rounded(.up))
    }
}

/// Why the chosen model can't be used right now.
enum ModelUnavailableError: LocalizedError {
    case appleIntelligenceOff
    case deviceNotEligible
    case modelNotReady
    case privateCloudUnavailable
    /// The app wasn't signed with the managed Private Cloud Compute entitlement, so the system
    /// rejects every request even though the model reports itself available.
    case privateCloudNotEntitled
    case missingAPIKey(ModelProvider)
    /// No downloaded model is chosen, or its files are missing.
    case localModelMissing

    var errorDescription: String? {
        switch self {
        case .appleIntelligenceOff:
            String(localized: "Turn on Apple Intelligence in System Settings to use the on-device model.")
        case .deviceNotEligible:
            String(localized: "This Mac doesn't support Apple Intelligence. Choose another model in Settings.")
        case .modelNotReady:
            String(localized: "The on-device model is still downloading. Try again shortly.")
        case .privateCloudUnavailable:
            String(localized: "Private Cloud Compute isn't available right now.")
        case .privateCloudNotEntitled:
            String(localized: "This build of Omnis isn't signed for Private Cloud Compute.")
        case .missingAPIKey(let provider):
            String(localized: "Add your \(provider.displayName) API key in Settings.")
        case .localModelMissing:
            String(localized: "Download a model in Settings to answer on this Mac.")
        }
    }
}

/// Turns the user's provider choice into a concrete `LanguageModel`.
struct ModelResolver {
    let settings: ModelSettings

    /// Tokens kept free for the instructions and the answer in the small on-device context.
    private static let onDeviceReserve = 900
    /// Private Cloud Compute also spends context on reasoning.
    private static let privateCloudReserve = 6_000
    /// Cloud models have huge windows; capping the prompt keeps answers fast and cheap.
    private static let cloudPromptBudget = 48_000
    /// Downloaded models: room for long chats without the KV cache taking most of the Mac's memory.
    private static let localPromptBudget = 32_768
    /// Kept free for the instructions, thinking and the answer.
    private static let localReserve = 6_000

    func resolve(_ provider: ModelProvider? = nil) async throws -> ResolvedModel {
        switch provider ?? settings.provider {
        case .local:
            return try local()

        case .appleOnDevice:
            return try onDevice()

        case .applePrivateCloud:
            guard Self.hasPrivateCloudEntitlement else {
                throw ModelUnavailableError.privateCloudNotEntitled
            }
            let model = PrivateCloudComputeLanguageModel()
            guard case .available = model.availability else {
                throw ModelUnavailableError.privateCloudUnavailable
            }
            let contextSize = (try? await model.contextSize) ?? 32_768
            return ResolvedModel(
                provider: .applePrivateCloud,
                model: model,
                promptBudget: contextSize - Self.privateCloudReserve,
                charactersPerToken: 3.5,
                thinkingModel: model
            )

        case .anthropic:
            guard let key = settings.apiKey(for: .anthropic) else {
                throw ModelUnavailableError.missingAPIKey(.anthropic)
            }
            let model = AnthropicLanguageModel(modelID: settings.anthropicModel, apiKey: key)
            return ResolvedModel(
                provider: .anthropic,
                model: model,
                promptBudget: Self.cloudPromptBudget,
                charactersPerToken: 4,
                // Haiku 4.5 takes no effort level, so how much it thinks can't be steered.
                thinkingModel: settings.anthropicModel.hasPrefix("claude-haiku") ? nil : model
            )

        case .openAI:
            guard let key = settings.apiKey(for: .openAI) else {
                throw ModelUnavailableError.missingAPIKey(.openAI)
            }
            let model = OpenAILanguageModel(modelID: settings.openAIModel, apiKey: key)
            // Only reasoning models (GPT-5, the o series) accept a reasoning effort.
            let reasons = ["gpt-5", "o1", "o3", "o4"].contains { settings.openAIModel.hasPrefix($0) }
            return ResolvedModel(
                provider: .openAI,
                model: model,
                promptBudget: Self.cloudPromptBudget,
                charactersPerToken: 4,
                thinkingModel: reasons ? model : nil
            )
        }
    }

    /// The model for everything but realtime work (live notes, auto answer): highlights,
    /// titles, definitions and quick checks. That's the user's chosen model (Bonsai, normally),
    /// or Apple's on-device model if it can't be used or can't produce the structured output
    /// the job needs.
    func preferred(needsGuidedGeneration: Bool = false) async -> ResolvedModel? {
        if let chosen = try? await resolve(), !needsGuidedGeneration || chosen.supportsGuidedGeneration {
            return chosen
        }
        return try? onDevice()
    }

    /// The downloaded model (Bonsai), run with MLX. Loading is deferred to the first request
    /// and then shared process-wide, so resolving it again is cheap.
    func local() throws -> ResolvedModel {
        guard let option = settings.localModel, LocalModelStore.isComplete(option) else {
            throw ModelUnavailableError.localModelMissing
        }
        // Thinking off: Bonsai's template thinks by default, and that hidden thinking can run
        // for minutes before a word of the answer appears. Without `.reasoning` declared, MLX
        // renders the prompt with thinking disabled, so answers start streaming right away.
        let model = LocalModel.languageModel(at: option.directory, vision: option.supportsVision, reasoning: false)
        let chatBudget = option.chatBudget
        return ResolvedModel(
            provider: .local,
            model: model,
            // Far below what the models can read, to keep memory bounded while answering.
            promptBudget: min(option.contextLength, Self.localPromptBudget) - Self.localReserve,
            charactersPerToken: 3.5,
            load: (option.name, { try await model.preload() }),
            chatBudget: chatBudget,
            maximumAnswerTokens: 800,
            // A third (or, on a tight budget, a sixth) of the image tokens of a full-size
            // capture; the screen's text still arrives in full from text recognition.
            maximumImageDimension: chatBudget >= 3_000 ? 1024 : 768,
            // Thinking on, for questions that need it. MLX caches loaded models by id, so
            // this shares the weights above rather than loading them twice.
            thinkingModel: LocalModel.languageModel(at: option.directory, vision: option.supportsVision, reasoning: true)
        )
    }

    /// The on-device model, which is also the fallback when Private Cloud Compute fails.
    func onDevice() throws -> ResolvedModel {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(.appleIntelligenceNotEnabled):
            throw ModelUnavailableError.appleIntelligenceOff
        case .unavailable(.deviceNotEligible):
            throw ModelUnavailableError.deviceNotEligible
        default:
            throw ModelUnavailableError.modelNotReady
        }
        return ResolvedModel(
            provider: .appleOnDevice,
            model: model,
            promptBudget: model.contextSize - Self.onDeviceReserve,
            // Conservative, so estimates rarely overshoot the small window.
            charactersPerToken: 3.2
        )
    }

    /// Whether `provider` is set up well enough to try (for Settings).
    func status(of provider: ModelProvider) -> String? {
        switch provider {
        case .local:
            return (try? local()) == nil ? String(localized: "Download a model to use it") : nil
        case .appleOnDevice:
            return (try? onDevice()) == nil ? String(localized: "Unavailable on this Mac") : nil
        case .applePrivateCloud:
            guard Self.hasPrivateCloudEntitlement else {
                return String(localized: "Not enabled for this build · answers on device")
            }
            if case .available = PrivateCloudComputeLanguageModel().availability { return nil }
            return String(localized: "Unavailable · answers on device")
        case .anthropic, .openAI:
            return settings.apiKey(for: provider) == nil ? String(localized: "Needs an API key") : nil
        }
    }

    /// Whether this process was signed with the Private Cloud Compute entitlement. Without it,
    /// `PrivateCloudComputeLanguageModel` still reports `.available`, but every request fails.
    static let hasPrivateCloudEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.private-cloud-compute" as CFString, nil)
        else { return false }
        return (value as? Bool) ?? false
    }()
}
