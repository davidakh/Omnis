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
    ///   - directory: The folder holding the model's files. Its name is the model's identity
    ///     in the cache, so each model needs its own folder.
    ///   - vision: Load it as a vision-language model, so it can look at images.
    ///   - reasoning: The model can think before it answers.
    ///   - tools: The model can call tools (e.g. to look things up).
    public static func languageModel(
        at directory: URL,
        vision: Bool,
        reasoning: Bool,
        tools: Bool = true
    ) -> MLXLanguageModel {
        let configuration = ModelConfiguration(directory: directory)
        var capabilities: [LanguageModelCapabilities.Capability] = [.guidedGeneration]
        if vision { capabilities.append(.vision) }
        if reasoning { capabilities.append(.reasoning) }
        if tools { capabilities.append(.toolCalling) }
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
