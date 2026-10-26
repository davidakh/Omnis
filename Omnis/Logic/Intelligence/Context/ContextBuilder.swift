import CoreGraphics
import Foundation
import FoundationModels

/// A finished question and answer earlier in the same thread.
struct AskTurn {
    let question: String
    let answer: String
    /// Whether the answer was based on the screen.
    var usedScreen = false
    /// Whether the answer was based on a web search.
    var usedWeb = false
}

/// Everything one question is answered from.
struct AskContext {
    let instructions: String
    let prompt: String
    /// The screen, for models that accept images.
    let image: CGImage?
}

/// Assembles the context for a question: the screen and web results when included, fitted to
/// the chosen model's budget. Earlier turns reach the model as real conversation turns (see `AskService`).
struct ContextBuilder {
    /// Share of the prompt budget each part may use.
    private enum Share {
        static let screen = 0.20
        static let web = 0.45
        /// Of the web's share: the results' titles and snippets, before the pages read.
        static let webSnippets = 0.15
    }

    func build(
        question: String,
        screen: ScreenSnapshot?,
        screenNote: String?,
        web: WebContext?,
        webNote: String?,
        model: ResolvedModel
    ) async -> AskContext {
        let budget = model.answerBudget

        var screenBlock = ""
        if let screen {
            screenBlock = screenText(screen, tokens: Int(Double(budget) * Share.screen), model: model)
        } else if let screenNote {
            screenBlock = "On screen: unavailable. \(screenNote)"
        }

        var webBlock = ""
        if let web {
            webBlock = webText(web, question: question, tokens: Int(Double(budget) * Share.web), model: model)
        } else if let webNote {
            webBlock = "From the web: unavailable. \(webNote)"
        }

        return AskContext(
            instructions: instructions(
                hasScreen: screen != nil,
                screenMissing: screen == nil && screenNote != nil,
                hasWeb: web != nil,
                webMissing: web == nil && webNote != nil
            ),
            prompt: render(question: question, blocks: [screenBlock, webBlock]),
            image: model.supportsVision ? screen.map { scaled($0.image, toFit: model.maximumImageDimension) } : nil
        )
    }

    /// The image shrunk so its longer side is at most `dimension` pixels (unchanged without a limit).
    private func scaled(_ image: CGImage, toFit dimension: Int?) -> CGImage {
        guard let dimension, max(image.width, image.height) > dimension else { return image }
        let scale = Double(dimension) / Double(max(image.width, image.height))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    // MARK: - Pieces

    private func instructions(hasScreen: Bool, screenMissing: Bool, hasWeb: Bool, webMissing: Bool) -> String {
        var text = """
        You are Omnis, an assistant on the user's Mac. Use what's relevant: earlier in this \
        conversation, their screen and web results when included. Answer from general knowledge, \
        and say so when unsure. Be concise: a few sentences or a short list, unless they ask for more.
        """
        if hasWeb || webMissing {
            text += " Today is \(Date.now.formatted(date: .complete, time: .omitted))."
        }
        if hasWeb {
            text += """
             Results of a web search for this question are included under "From the web", \
            numbered, some with the page's text. For anything current or specific, rely on them \
            over what you remember, and name the site you used (e.g. "according to bbc.com"). \
            If they don't answer the question, say so rather than guessing.
            """
        }
        if webMissing {
            text += """
             A web search for this question failed; "From the web" says why. Don't present \
            current facts as checked; say you couldn't look them up.
            """
        }
        if hasScreen {
            text += """
             The window the user is looking at right now is included, as its text under "On screen" \
            and as an image. "This", "here", "on my screen" and "what I'm looking at" refer to it; \
            read it before answering.
            """
        }
        if screenMissing {
            text += """
             The user's screen could not be included this time; "On screen" says why. You can't \
            see it, so if they ask about it, tell them that and why, and don't describe or guess \
            what's on it.
            """
        }
        return text
    }

    private func render(question: String, blocks: [String]) -> String {
        let blocks = blocks.filter { !$0.isEmpty }
        guard !blocks.isEmpty else { return question }
        return blocks.joined(separator: "\n\n---\n\n") + "\n\n---\n\nQuestion: \(question)"
    }

    /// Numbered results, each with its snippet, and the text of the pages that were read.
    private func webText(_ web: WebContext, question: String, tokens: Int, model: ResolvedModel) -> String {
        let header = web.query.map { "From the web, searching \"\($0)\":" } ?? "From the web:"
        let snippetTokens = Int(Double(tokens) * Share.webSnippets) / max(1, web.results.count)
        let pageTokens = Int(Double(tokens) * (1 - Share.webSnippets)) / max(1, web.pages.count)
        var parts = [header]
        for (index, result) in web.results.enumerated() {
            var entry = "[\(index + 1)] \(result.title) (\(result.site))"
            if !result.snippet.isEmpty {
                entry += "\n" + fit(result.snippet, tokens: snippetTokens, model: model)
            }
            if let page = web.pages[result.url] {
                entry += "\nPage text:\n" + passages(of: page, about: [web.query ?? "", question].joined(separator: " "), tokens: pageTokens, model: model)
            }
            parts.append(entry)
        }
        return parts.joined(separator: "\n\n")
    }

    private func screenText(_ screen: ScreenSnapshot, tokens: Int, model: ResolvedModel) -> String {
        let title = screen.windowTitle.map { ", \"\($0)\"" } ?? ""
        var parts = ["On screen, \(screen.appName)\(title):"]
        if let description = screen.visualDescription, !description.isEmpty {
            parts.append("What it looks like: \(description)")
        }
        if !screen.labels.isEmpty {
            parts.append("Shows: \(screen.labels.joined(separator: ", "))")
        }
        if !screen.codes.isEmpty {
            parts.append("QR codes and barcodes: \(screen.codes.joined(separator: "; "))")
        }
        // Rows in reading order; " | " separates columns and table cells.
        parts.append(screen.text.isEmpty
            ? "Text: (none readable)"
            : "Text (rows in reading order, \" | \" between columns):\n" + fit(screen.text, tokens: tokens, model: model))
        return parts.joined(separator: "\n")
    }

    /// The paragraphs of a page that best match the question, in page order, within `tokens`.
    /// Pages run long and the facts asked about are rarely at the top, so this carries more of
    /// what matters than the page's opening would, in fewer tokens (a downloaded model reads
    /// every one before its first word).
    private func passages(of page: String, about question: String, tokens: Int, model: ResolvedModel) -> String {
        let characters = Int(Double(tokens) * model.charactersPerToken)
        guard page.count > characters else { return page }
        let terms = Self.terms(in: question)
        let paragraphs = page.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !terms.isEmpty, paragraphs.count > 1 else { return fit(page, tokens: tokens, model: model) }

        // How many of the question's words a paragraph contains, with a little credit for being
        // early (the opening usually says what the page is about).
        let scores = paragraphs.enumerated().map { index, paragraph in
            Double(terms.intersection(Self.terms(in: paragraph)).count) + 0.5 / Double(index + 1)
        }
        let ranked = paragraphs.indices.sorted { scores[$0] > scores[$1] }
        var chosen = Set<Int>()
        var used = 0
        for index in ranked {
            let length = paragraphs[index].count + 1
            if used + length > characters { continue }
            chosen.insert(index)
            used += length
        }
        guard !chosen.isEmpty else { return fit(page, tokens: tokens, model: model) }
        // Page order, with "…" where paragraphs were left out.
        var pieces: [String] = []
        var previous = -1
        for index in chosen.sorted() {
            if index != previous + 1 { pieces.append("…") }
            pieces.append(paragraphs[index])
            previous = index
        }
        return pieces.joined(separator: "\n")
    }

    /// Lowercased words of three or more letters, without the most common filler.
    private static func terms(in text: String) -> Set<String> {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(words.filter { $0.count >= 3 && !stopWords.contains($0) })
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "was", "were", "what", "when", "where", "which", "who", "why",
        "how", "does", "did", "with", "this", "that", "from", "about", "into", "than", "then",
        "there", "their", "they", "have", "has", "had", "you", "your", "can", "will", "would",
        "should", "could", "its", "not", "but", "all", "any", "more", "most", "some", "such"
    ]

    private func fit(_ text: String, tokens: Int, model: ResolvedModel) -> String {
        let characters = Int(Double(tokens) * model.charactersPerToken)
        guard text.count > characters else { return text }
        return String(text.prefix(max(0, characters))) + "…"
    }
}
