import Foundation
import FoundationModels

/// OpenAI, through the Chat Completions API, as a Foundation Models `LanguageModel`.
nonisolated struct OpenAILanguageModel: LanguageModel {
    typealias Executor = OpenAIExecutor

    var modelID: String
    var apiKey: String

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.vision])
    }

    var executorConfiguration: OpenAIExecutor.Configuration {
        .init(modelID: modelID, apiKey: apiKey)
    }
}

nonisolated struct OpenAIExecutor: LanguageModelExecutor {
    struct Configuration: Hashable, Sendable {
        var modelID: String
        var apiKey: String
    }

    typealias Model = OpenAILanguageModel

    private static let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    private static let provider = "OpenAI"

    let configuration: Configuration

    init(configuration: Configuration) throws {
        self.configuration = configuration
    }

    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: OpenAILanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        var urlRequest = URLRequest(url: Self.endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 600
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "authorization")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body(for: request))

        var inputTokens = 0
        var cachedTokens = 0
        var outputTokens = 0
        var reasoningTokens = 0

        try await ServerSentEvents.stream(urlRequest, provider: Self.provider) { _, json in
            if let error = json["error"] as? [String: Any] {
                throw ProviderError.streamError(
                    provider: Self.provider,
                    message: (error["message"] as? String) ?? "Unknown error"
                )
            }

            if let choice = (json["choices"] as? [[String: Any]])?.first {
                if let delta = choice["delta"] as? [String: Any] {
                    if let text = delta["content"] as? String, !text.isEmpty {
                        await channel.send(.response(action: .appendText(
                            text, tokenCount: ServerSentEvents.estimatedTokens(text)
                        )))
                    }
                    if delta["refusal"] as? String != nil {
                        throw ProviderError.refused(provider: Self.provider)
                    }
                }
                if choice["finish_reason"] as? String == "content_filter" {
                    throw ProviderError.refused(provider: Self.provider)
                }
            }

            // With include_usage, the last chunk carries usage and no choices.
            if let usage = json["usage"] as? [String: Any] {
                inputTokens = (usage["prompt_tokens"] as? Int) ?? 0
                outputTokens = (usage["completion_tokens"] as? Int) ?? 0
                cachedTokens = ((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int) ?? 0
                reasoningTokens = ((usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int) ?? 0
            }
        }

        await channel.send(.response(action: .updateUsage(
            input: .init(totalTokenCount: inputTokens, cachedTokenCount: cachedTokens),
            output: .init(totalTokenCount: outputTokens, reasoningTokenCount: reasoningTokens)
        )))
    }

    // MARK: - Request body

    private func body(for request: LanguageModelExecutorGenerationRequest) -> [String: Any] {
        let (system, conversation) = TranscriptConversion.messages(from: request.transcript)
        var messages: [[String: Any]] = []
        if !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages += conversation.map(encode)

        // Temperature is left at the default: reasoning models reject other values.
        var body: [String: Any] = [
            "model": configuration.modelID,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": messages
        ]
        if let maximum = request.generationOptions.maximumResponseTokens {
            body["max_completion_tokens"] = maximum
        }
        if let effort = effort(for: request.contextOptions.reasoningLevel) {
            body["reasoning_effort"] = effort
        }
        return body
    }

    private func encode(_ message: ProviderMessage) -> [String: Any] {
        let content: [[String: Any]] = message.parts.map { part in
            switch part {
            case .text(let text):
                ["type": "text", "text": text]
            case .image(let jpeg):
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]]
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
}
