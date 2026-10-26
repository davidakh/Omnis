import Foundation

/// One web search result.
struct WebResult: Hashable, Sendable {
    let title: String
    let url: URL
    let snippet: String
    /// The site's own name ("Encyclopedia Britannica"), when its page was read and says it.
    var siteName: String?

    /// How the source is shown: the site's own name, else the name its titles end with
    /// ("… - Wikipedia"), else its domain.
    var displayName: String { siteName ?? titleSiteName ?? site }

    /// The last part of the title after " - ", " | " or " — ", when it names this site (its
    /// letters appear in the domain), so "Paris - Wikipedia" gives "Wikipedia".
    private var titleSiteName: String? {
        let separators = [" - ", " | ", " — ", " – "]
        guard let range = separators.compactMap({ title.range(of: $0, options: .backwards) }).max(by: { $0.lowerBound < $1.lowerBound })
        else { return nil }
        let name = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let letters = name.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !letters.isEmpty, name.count <= 40, site.lowercased().contains(letters) else { return nil }
        return name
    }

    /// The site's name for showing and citing: "bbc.com".
    var site: String {
        let host = url.host(percentEncoded: false) ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

/// What the web added to a question: the results, and the readable text of the pages read.
struct WebContext: Sendable {
    /// What was searched for; nil when only links from the question were read.
    let query: String?
    let results: [WebResult]
    /// Readable text by page, for the pages that were read.
    let pages: [URL: String]

    /// The sources to show under the answer: pages that were read first, then other results.
    var sources: [WebResult] {
        let read = results.filter { pages[$0.url] != nil }
        return Array((read + results.filter { pages[$0.url] == nil }).prefix(4))
    }
}

enum WebSearchError: LocalizedError {
    case noResults
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noResults: String(localized: "The web search found nothing.")
        case .failed(let reason): String(localized: "Couldn't search the web: \(reason)")
        }
    }
}

/// Searches the web with DuckDuckGo (no account or key needed) and reads the top pages, so
/// answers can use current, specific facts.
nonisolated enum WebSearch {
    /// Results kept from a search.
    private static let resultLimit = 6
    /// Pages read in full; the other results contribute their snippets.
    private static let pagesToRead = 3
    /// Text kept per page before the context builder fits it to the model's budget.
    private static let pageCharacterLimit = 24_000
    /// Larger pages are mostly scripts and markup; they're skipped rather than parsed.
    private static let pageByteLimit = 4 * 1_048_576
    /// How long pages may take to arrive once the search is done. A slower page is left to its
    /// snippet rather than holding up the answer.
    private static let readingDeadline = Duration.milliseconds(2_500)

    /// No cookies or cache, and short timeouts: a slow site is skipped rather than waited on.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
            "Accept-Language": Locale.preferredLanguages.prefix(3).joined(separator: ",")
        ]
        return URLSession(configuration: configuration)
    }()

    /// Searches for `query` (when given), adds `links` from the question, and reads the top pages.
    @concurrent
    static func context(query: String?, links: [URL]) async throws -> WebContext {
        var results = links.map { WebResult(title: $0.host(percentEncoded: false) ?? $0.absoluteString, url: $0, snippet: "") }
        if let query {
            do {
                let found = try await search(query)
                results += found.filter { result in !results.contains { $0.url == result.url } }
            } catch where !results.isEmpty {
                // The pasted links can still be read.
            }
        }
        guard !results.isEmpty else { throw WebSearchError.noResults }

        // Read the top pages at once; one that fails or misses the deadline is left to its snippet.
        let toRead = Array(results.prefix(pagesToRead).map(\.url))
        let pages = await withTaskGroup(of: (URL, ReadPage?)?.self) { group in
            for url in toRead {
                group.addTask { (url, try? await readPage(url)) }
            }
            group.addTask {
                try? await Task.sleep(for: readingDeadline)
                return nil
            }
            var pages: [URL: ReadPage] = [:]
            var remaining = toRead.count
            for await finished in group {
                // `nil` is the deadline.
                guard let (url, page) = finished else { break }
                if let page, !page.text.isEmpty { pages[url] = page }
                remaining -= 1
                if remaining == 0 { break }
            }
            group.cancelAll()
            return pages
        }
        for index in results.indices {
            results[index].siteName = pages[results[index].url]?.siteName
        }
        return WebContext(query: query, results: results, pages: pages.mapValues(\.text))
    }

    // MARK: - Searching

    private static func search(_ query: String) async throws -> [WebResult] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { throw WebSearchError.noResults }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebSearchError.failed(String(localized: "the search service returned an error (\(http.statusCode))."))
        }
        let results = parseResults(String(decoding: data, as: UTF8.self))
        guard !results.isEmpty else { throw WebSearchError.noResults }
        return results
    }

    /// Reads DuckDuckGo's HTML results: each result's link is a `result__a` anchor, followed by
    /// its `result__snippet`. Ads and DuckDuckGo's own links are skipped.
    static func parseResults(_ html: String) -> [WebResult] {
        var results: [WebResult] = []
        for chunk in html.components(separatedBy: "class=\"result__a\"").dropFirst() {
            guard let href = Patterns.href.firstCapture(in: chunk),
                  let url = resultURL(from: decodeEntities(href)),
                  let host = url.host(percentEncoded: false), !host.hasSuffix("duckduckgo.com")
            else { continue }
            let title = Patterns.anchorText.firstCapture(in: chunk).map(plainText) ?? host
            let snippet = Patterns.snippet.firstCapture(in: chunk).map(plainText) ?? ""
            guard !results.contains(where: { $0.url == url }) else { continue }
            results.append(WebResult(title: title.isEmpty ? host : title, url: url, snippet: snippet))
            if results.count == resultLimit { break }
        }
        return results
    }

    /// Result links go through DuckDuckGo's redirect (`//duckduckgo.com/l/?uddg=<target>`).
    private static func resultURL(from href: String) -> URL? {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard let components = URLComponents(string: absolute) else { return nil }
        if let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
            return URL(string: target).flatMap(webURL)
        }
        return components.url.flatMap(webURL)
    }

    private static func webURL(_ url: URL) -> URL? {
        ["http", "https"].contains(url.scheme?.lowercased()) ? url : nil
    }

    // MARK: - Reading pages

    private struct ReadPage {
        let text: String
        let siteName: String?
    }

    private static func readPage(_ url: URL) async throws -> ReadPage? {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= pageByteLimit else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "text/html"
        let raw = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let text: String
        var siteName: String?
        if type.contains("html") || type.contains("xml") {
            text = readableText(fromHTML: raw)
            siteName = (Patterns.siteName.firstCapture(in: raw) ?? Patterns.siteNameContentFirst.firstCapture(in: raw))
                .map(plainText)
                .flatMap { $0.isEmpty || $0.count > 40 ? nil : $0 }
        } else if type.hasPrefix("text/") || type.contains("json") {
            text = raw
        } else {
            // PDFs, images and other files aren't read.
            return nil
        }
        return ReadPage(text: String(text.prefix(pageCharacterLimit)), siteName: siteName)
    }

    /// The page's readable text: its main content when it marks one, without scripts, menus,
    /// headers and footers, one paragraph per line.
    static func readableText(fromHTML html: String) -> String {
        var cleaned = Patterns.ignoredBlock.replace(in: html, with: " ")
        cleaned = Patterns.boilerplateBox.replace(in: cleaned, with: " ")
        cleaned = Patterns.comment.replace(in: cleaned, with: " ")
        // `<article>` or `<main>` holds the content on most pages; listing pages with small
        // cards fall back to the whole body.
        if let main = Patterns.article.firstCapture(in: cleaned) ?? Patterns.main.firstCapture(in: cleaned) {
            let text = textLines(main)
            if text.count >= 400 { return text }
        }
        return textLines(cleaned)
    }

    private static func textLines(_ html: String) -> String {
        var text = Patterns.blockEnd.replace(in: html, with: "\n")
        text = Patterns.cellEnd.replace(in: text, with: " | ")
        text = decodeEntities(Patterns.tag.replace(in: text, with: " "))
        return text
            .components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { line in
                // Menu items and buttons are a word or two; keep sentences and short facts with numbers.
                let words = line.split(separator: " ").count
                return words >= 4 || (words >= 2 && line.contains(where: \.isNumber))
            }
            .joined(separator: "\n")
    }

    private static func plainText(_ html: String) -> String {
        decodeEntities(Patterns.tag.replace(in: html, with: ""))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    // MARK: - Entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
        "rdquo": "”", "laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "copy": "©",
        "reg": "®", "trade": "™", "deg": "°", "times": "×", "euro": "€", "pound": "£",
        "yen": "¥", "cent": "¢"
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&"), let regex = Patterns.entity.regex else { return text }
        let source = text as NSString
        var result = ""
        var location = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: location, length: match.range.location - location))
            let name = source.substring(with: match.range(at: 1))
            result += decodedEntity(name) ?? source.substring(with: match.range)
            location = match.range.location + match.range.length
        }
        result += source.substring(from: location)
        return result
    }

    private static func decodedEntity(_ name: String) -> String? {
        guard name.hasPrefix("#") else { return namedEntities[name.lowercased()] }
        let digits = name.dropFirst()
        let value = digits.first == "x" || digits.first == "X"
            ? UInt32(digits.dropFirst(), radix: 16)
            : UInt32(digits)
        return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
    }
}

/// HTML patterns, compiled once. NSRegularExpression rather than Swift Regex: it's far faster
/// on the megabytes of markup a page can be.
private nonisolated enum Patterns {
    static let href = Pattern(#"href="([^"]+)""#)
    static let anchorText = Pattern(#"^[^>]*>(.*?)</a>"#)
    static let snippet = Pattern(#"class="result__snippet"[^>]*>(.*?)</(?:a|div|td)>"#)
    static let ignoredBlock = Pattern(
        #"<(script|style|noscript|svg|nav|header|footer|aside|form|iframe|template|button|select|figure)\b[^>]*>.*?</\1\s*>"#
    )
    /// Sidebars, navigation boxes and footnote markers (Wikipedia's especially), which would
    /// otherwise fill a page's share of the prompt before its first paragraph.
    static let boilerplateBox = Pattern(
        #"<(table|div|sup)\b[^>]*(?:class="[^"]*\b(?:sidebar|navbox|infobox|vertical-navbox|reference|reflist|toc|hatnote|mw-editsection)\b[^"]*"|role="navigation")[^>]*>.*?</\1\s*>"#
    )
    static let comment = Pattern(#"<!--.*?-->"#)
    /// The site's name as it gives it to link previews (Open Graph), or as a web app.
    static let siteName = Pattern(
        #"<meta\b[^>]*\b(?:property|name)=["'](?:og:site_name|application-name)["'][^>]*\bcontent=["']([^"']+)["']"#
    )
    static let siteNameContentFirst = Pattern(
        #"<meta\b[^>]*\bcontent=["']([^"']+)["'][^>]*\b(?:property|name)=["'](?:og:site_name|application-name)["']"#
    )
    static let article = Pattern(#"<article\b[^>]*>(.*)</article>"#)
    static let main = Pattern(#"<main\b[^>]*>(.*)</main>"#)
    static let blockEnd = Pattern(#"<(?:br|/p|/div|/li|/h[1-6]|/tr|/section|/blockquote|/pre|/table|/ul|/ol|/dd|/dt)\b[^>]*>"#)
    static let cellEnd = Pattern(#"</t[dh]\s*>"#)
    static let tag = Pattern(#"<[^>]*>"#)
    static let entity = Pattern(#"&(#[xX]?[0-9a-fA-F]+|[a-zA-Z]+);"#)
}

private nonisolated struct Pattern: Sendable {
    let regex: NSRegularExpression?

    init(_ pattern: String) {
        regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    func replace(in text: String, with template: String) -> String {
        guard let regex else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
        )
    }

    /// The first capture group of the first match.
    func firstCapture(in text: String) -> String? {
        guard let match = regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
