import CoreGraphics
import Foundation
import FoundationModels
import ImageIO
import UniformTypeIdentifiers

// Shared plumbing for the cloud `LanguageModel` executors (Claude, OpenAI): turning a
// Foundation Models transcript into chat messages, encoding images, reading server-sent
// events, and mapping HTTP failures to errors. Executors run off the main actor, so
// everything here is nonisolated.

/// A chat message in the shape both providers expect: a role and text / image parts.
nonisolated struct ProviderMessage {
    enum Role { case user, assistant }
    enum Part {
        case text(String)
        /// JPEG bytes.
        case image(Data)
    }

    let role: Role
    var parts: [Part]
}

nonisolated enum TranscriptConversion {
    /// Splits a transcript into the system prompt (all instructions) and the conversation.
    /// Tool calls and reasoning entries are skipped; these models are used without tools.
    static func messages(from transcript: Transcript) -> (system: String, messages: [ProviderMessage]) {
        var system: [String] = []
        var messages: [ProviderMessage] = []

        for entry in transcript {
            switch entry {
            case .instructions(let instructions):
                system.append(text(of: instructions.segments))
            case .prompt(let prompt):
                append(ProviderMessage(role: .user, parts: parts(of: prompt.segments)), to: &messages)
            case .response(let response):
                append(ProviderMessage(role: .assistant, parts: parts(of: response.segments)), to: &messages)
            default:
                continue
            }
        }
        return (system.filter { !$0.isEmpty }.joined(separator: "\n\n"), messages)
    }

    /// Both APIs want alternating roles, so consecutive same-role messages are merged.
    private static func append(_ message: ProviderMessage, to messages: inout [ProviderMessage]) {
        guard !message.parts.isEmpty else { return }
        if let last = messages.last, last.role == message.role {
            messages[messages.count - 1].parts += message.parts
        } else {
            messages.append(message)
        }
    }

    private static func parts(of segments: [Transcript.Segment]) -> [ProviderMessage.Part] {
        segments.compactMap { segment in
            switch segment {
            case .text(let text):
                return text.content.isEmpty ? nil : .text(text.content)
            case .structure(let structured):
                return .text(structured.content.jsonString)
            case .attachment(let attachment):
                guard case .image(let image) = attachment.content,
                      let jpeg = ImageEncoding.jpeg(image.cgImage) else { return nil }
                return .image(jpeg)
            default:
                return nil
            }
        }
    }

    private static func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            if case .text(let text) = segment { return text.content }
            return nil
        }
        .joined(separator: "\n")
    }
}

nonisolated enum ImageEncoding {
    /// Both providers downscale anything larger, so sending more only costs upload time.
    static let maxDimension: CGFloat = 1568

    static func jpeg(_ image: CGImage, quality: CGFloat = 0.8) -> Data? {
        let scaled = downscaled(image) ?? image
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func downscaled(_ image: CGImage) -> CGImage? {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxDimension else { return nil }
        let scale = maxDimension / longest
        let width = Int(CGFloat(image.width) * scale)
        let height = Int(CGFloat(image.height) * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

/// Failures specific to talking to a cloud provider.
nonisolated enum ProviderError: LocalizedError {
    case missingAPIKey(provider: String)
    case invalidAPIKey(provider: String)
    case overloaded(provider: String)
    case refused(provider: String)
    case server(provider: String, status: Int, message: String?)
    case streamError(provider: String, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            String(localized: "Add your \(provider) API key in Settings.")
        case .invalidAPIKey(let provider):
            String(localized: "\(provider) rejected the API key. Check it in Settings.")
        case .overloaded(let provider):
            String(localized: "\(provider) is overloaded right now. Try again in a moment.")
        case .refused(let provider):
            String(localized: "\(provider) declined to answer this request.")
        case .server(let provider, let status, let message):
            message.map { String(localized: "\(provider) error \(status): \($0)") }
                ?? String(localized: "\(provider) returned error \(status).")
        case .streamError(let provider, let message):
            String(localized: "\(provider) stopped with an error: \(message)")
        }
    }
}

nonisolated enum ServerSentEvents {
    /// Sends `request` and calls `handle` with each event's name and JSON payload, in order.
    /// Non-2xx responses are turned into errors before any event is delivered.
    static func stream(
        _ request: URLRequest,
        provider: String,
        handle: (_ event: String?, _ data: [String: Any]) async throws -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw await error(status: status, bytes: bytes, response: response as? HTTPURLResponse, provider: provider)
        }

        var event: String?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { return }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                try await handle(event, json)
                event = nil
            }
        }
    }

    private static func error(
        status: Int,
        bytes: URLSession.AsyncBytes,
        response: HTTPURLResponse?,
        provider: String
    ) async -> Error {
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count > 16_384 { break }
            }
        } catch {}
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String

        switch status {
        case 401, 403:
            return ProviderError.invalidAPIKey(provider: provider)
        case 429:
            let retryAfter = response?.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            return LanguageModelError.rateLimited(.init(
                resetDate: retryAfter.map { Date.now.addingTimeInterval($0) },
                debugDescription: message ?? "\(provider) rate limit reached"
            ))
        case 529, 503:
            return ProviderError.overloaded(provider: provider)
        default:
            return ProviderError.server(provider: provider, status: status, message: message)
        }
    }

    /// Rough token count for streamed text (about four characters per token).
    static func estimatedTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}
