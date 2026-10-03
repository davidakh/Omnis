import Foundation
import FoundationModels

/// A model ready to prompt, plus what context building needs to know about it.
struct ResolvedModel {
    let provider: ModelProvider
    let model: any LanguageModel
    /// Tokens the prompt (context + question) may use, after reserving room for the
    /// instructions and the answer.
    let promptBudget: Int
    /// For estimating token counts from text before the prompt is assembled.
    let charactersPerToken: Double

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
    case missingAPIKey(ModelProvider)

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
        case .missingAPIKey(let provider):
            String(localized: "Add your \(provider.displayName) API key in Settings.")
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

    func resolve(_ provider: ModelProvider? = nil) async throws -> ResolvedModel {
        switch provider ?? settings.provider {
        case .appleOnDevice:
            return try onDevice()

        case .applePrivateCloud:
            let model = PrivateCloudComputeLanguageModel()
            guard case .available = model.availability else {
                throw ModelUnavailableError.privateCloudUnavailable
            }
            let contextSize = (try? await model.contextSize) ?? 32_768
            return ResolvedModel(
                provider: .applePrivateCloud,
                model: model,
                promptBudget: contextSize - Self.privateCloudReserve,
                charactersPerToken: 3.5
            )

        case .anthropic:
            guard let key = settings.apiKey(for: .anthropic) else {
                throw ModelUnavailableError.missingAPIKey(.anthropic)
            }
            return ResolvedModel(
                provider: .anthropic,
                model: AnthropicLanguageModel(modelID: settings.anthropicModel, apiKey: key),
                promptBudget: Self.cloudPromptBudget,
                charactersPerToken: 4
            )

        case .openAI:
            guard let key = settings.apiKey(for: .openAI) else {
                throw ModelUnavailableError.missingAPIKey(.openAI)
            }
            return ResolvedModel(
                provider: .openAI,
                model: OpenAILanguageModel(modelID: settings.openAIModel, apiKey: key),
                promptBudget: Self.cloudPromptBudget,
                charactersPerToken: 4
            )
        }
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
        case .appleOnDevice:
            return (try? onDevice()) == nil ? String(localized: "Unavailable on this Mac") : nil
        case .applePrivateCloud:
            if case .available = PrivateCloudComputeLanguageModel().availability { return nil }
            return String(localized: "Unavailable")
        case .anthropic, .openAI:
            return settings.apiKey(for: provider) == nil ? String(localized: "Needs an API key") : nil
        }
    }
}
