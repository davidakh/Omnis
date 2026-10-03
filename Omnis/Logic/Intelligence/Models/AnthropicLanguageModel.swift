import Foundation
import FoundationModels

/// Claude, through the Anthropic Messages API, as a Foundation Models `LanguageModel`, so a
/// `LanguageModelSession` can use it exactly like the system model.
nonisolated struct AnthropicLanguageModel: LanguageModel {
    typealias Executor = AnthropicExecutor

    var modelID: String
    var apiKey: String

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.vision])
    }

    var executorConfiguration: AnthropicExecutor.Configuration {
        .init(modelID: modelID, apiKey: apiKey)
    }
}

nonisolated struct AnthropicExecutor: LanguageModelExecutor {
    struct Configuration: Hashable, Sendable {
        var modelID: String
        var apiKey: String
    }

    typealias Model = AnthropicLanguageModel

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let provider = "Claude"
    /// Streaming, so a generous cap doesn't risk timeouts; it only bounds runaway output.
    private static let defaultMaxTokens = 64_000

    let configuration: Configuration

    init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: AnthropicLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if usesServerSideFallback {
            urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body(for: request))

        var inputTokens = 0
        var cachedTokens = 0
        var outputTokens = 0

        try await ServerSentEvents.stream(urlRequest, provider: Self.provider) { _, json in
            switch json["type"] as? String {
            case "message_start":
                let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any]
                inputTokens = (usage?["input_tokens"] as? Int) ?? 0
                cachedTokens = (usage?["cache_read_input_tokens"] as? Int) ?? 0

            case "content_block_delta":
                // Only text reaches the answer; thinking and fallback-marker blocks are skipped.
                guard let delta = json["delta"] as? [String: Any],
                      delta["type"] as? String == "text_delta",
                      let text = delta["text"] as? String, !text.isEmpty else { return }
                await channel.send(.response(action: .appendText(
                    text, tokenCount: ServerSentEvents.estimatedTokens(text)
                )))

            case "message_delta":
                if let usage = json["usage"] as? [String: Any], let output = usage["output_tokens"] as? Int {
                    outputTokens = output
                }
                // A safety decline arrives as a normal stop reason, not an HTTP error.
                if (json["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" {
                    throw ProviderError.refused(provider: Self.provider)
                }

            case "error":
                let error = json["error"] as? [String: Any]
                if error?["type"] as? String == "overloaded_error" {
                    throw ProviderError.overloaded(provider: Self.provider)
                }
                throw ProviderError.streamError(
                    provider: Self.provider,
                    message: (error?["message"] as? String) ?? "Unknown error"
                )

            default:
                break
            }
        }

        await channel.send(.response(action: .updateUsage(
            input: .init(totalTokenCount: inputTokens + cachedTokens, cachedTokenCount: cachedTokens),
            output: .init(totalTokenCount: outputTokens, reasoningTokenCount: 0)
        )))
    }

    // MARK: - Request body

    private func body(for request: LanguageModelExecutorGenerationRequest) -> [String: Any] {
        let (system, messages) = TranscriptConversion.messages(from: request.transcript)
        var body: [String: Any] = [
            "model": configuration.modelID,
            "max_tokens": request.generationOptions.maximumResponseTokens ?? Self.defaultMaxTokens,
            "stream": true,
            "messages": messages.map(encode)
        ]
        if !system.isEmpty { body["system"] = system }

        // Haiku 4.5 predates adaptive thinking and effort; newer models get both.
        // Temperature is deliberately never sent: the current models reject it.
        if !isHaiku {
            body["thinking"] = ["type": "adaptive"]
            if let effort = effort(for: request.contextOptions.reasoningLevel) {
                body["output_config"] = ["effort": effort]
            }
        }
        if usesServerSideFallback {
            // On a safety decline, the API retries on a suitable fallback model in-stream.
            body["fallbacks"] = "default"
        }
        return body
    }

    private func encode(_ message: ProviderMessage) -> [String: Any] {
        let content: [[String: Any]] = message.parts.map { part in
            switch part {
            case .text(let text):
                ["type": "text", "text": text]
            case .image(let jpeg):
                [
                    "type": "image",
                    "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]
                ]
            }
        }
        return ["role": message.role == .user ? "user" : "assistant", "content": content]
    }

    private func effort(for level: ContextOptions.ReasoningLevel?) -> String? {
        switch level {
        case .light: "low"
        case .moderate: "medium"
        case .deep: "high"
        case .custom(let value): value
        default: nil
        }
    }

    private var isHaiku: Bool { configuration.modelID.hasPrefix("claude-haiku") }

    /// The models with safety classifiers that can decline benign requests.
    private var usesServerSideFallback: Bool {
        configuration.modelID.hasPrefix("claude-opus-5") || configuration.modelID.hasPrefix("claude-fable")
    }
}
