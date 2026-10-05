import Foundation

/// Keeps generated summaries and notes to the summary itself: stops at the first repeat (small
/// models sometimes loop on a sentence or paragraph) and drops sentences about the writing
/// rather than the recording ("No ads were included", "I removed the sponsor segment").
enum SummaryCleanup {
    /// The text up to where it starts repeating itself, or nil if it doesn't. A sentence of some
    /// length that's already been written counts, as does a repeated paragraph.
    static func untilRepeat(_ text: String) -> String? {
        var seen = Set<String>()
        for sentence in sentences(in: text) {
            let key = normalized(sentence.text)
            if key.count >= 24, !seen.insert(key).inserted {
                let kept = String(text[..<sentence.range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                return kept.isEmpty ? nil : kept
            }
        }
        return nil
    }

    /// The finished text: cut at any repeat, without notes about what was left out or checked,
    /// with paragraph breaks tidied.
    static func clean(_ text: String) -> String {
        let base = untilRepeat(text) ?? text
        let paragraphs = base.components(separatedBy: "\n")
            .map { paragraph in
                sentences(in: paragraph)
                    .map(\.text)
                    .filter { !isAboutTheWriting($0) }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        return paragraphs.joined(separator: "\n\n")
    }

    /// "No advertisements were included", "Sponsor segments have been omitted", "I left out…":
    /// the model describing its own work instead of the recording.
    static func isAboutTheWriting(_ sentence: String) -> Bool {
        let text = sentence.lowercased()
        let mentionsAds = ["advertis", " ads", "ad read", "sponsor", "promotional", "commercial"].contains { text.contains($0) }
        let describesEditing = [
            "omit", "exclud", "remov", "left out", "leaving out", "not includ", "no ad", "skipp",
            "were not", "has been", "have been", "checked", "free of", "without any"
        ].contains { text.contains($0) }
        if mentionsAds && describesEditing { return true }
        // Openers and sign-offs about the summary itself.
        let selfReference = [
            "this summary", "the summary above", "here is the summary", "here's the summary",
            "here is a summary", "in summary, i", "i have ", "i've ", "as requested"
        ]
        return selfReference.contains { text.hasPrefix($0) || text.contains(" " + $0) }
    }

    // MARK: - Sentences

    private struct Sentence {
        let text: String
        let range: Range<String.Index>
    }

    private static func sentences(in text: String) -> [Sentence] {
        var result: [Sentence] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { substring, range, _, _ in
            guard let substring else { return }
            let trimmed = substring.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(Sentence(text: trimmed, range: range)) }
        }
        return result
    }

    private static func normalized(_ sentence: String) -> String {
        sentence.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
    }
}
