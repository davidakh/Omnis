import Foundation
import FoundationModels
@_exported import MLXFoundationModels
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Turns a downloaded model folder (config.json, tokenizer, safetensors) into a FoundationModels
/// `LanguageModel`, so the rest of Omnis uses it exactly like Apple's models.
@available(macOS 27.0, *)
public enum LocalModel {
    /// - Parameters:
    ///   - directory: The folder holding the model's files.
    ///   - name: A stable identity for the model cache (the Hugging Face repo id).
    ///   - vision: Load it as a vision-language model, so it can look at images.
    ///   - reasoning: The model can think before it answers.
    public static func languageModel(
        at directory: URL,
        name: String,
        vision: Bool,
        reasoning: Bool
    ) -> MLXLanguageModel {
        var configuration = ModelConfiguration(directory: directory)
        configuration.name = name
        var capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration]
        if vision { capabilities.append(.vision) }
        if reasoning { capabilities.append(.reasoning) }
        return MLXLanguageModel(
            configuration: configuration,
            capabilities: capabilities,
            weightsLocation: { _ in directory },
            load: { _, _ in
                // The weights are already on disk (Omnis downloads them itself), so this only
                // loads them. Vision models need the VLM factory to get their image processor.
                if vision {
                    try await VLMModelFactory.shared.loadContainer(from: directory, using: TokenizersLoader())
                } else {
                    try await LLMModelFactory.shared.loadContainer(from: directory, using: TokenizersLoader())
                }
            }
        )
    }
}
