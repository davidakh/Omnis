import NaturalLanguage

/// On-device sentence embeddings from NaturalLanguage. Vectors are L2-normalized, so cosine
/// similarity is a dot product.
///
/// Everything is embedded with one model, in the user's language (or English): vectors from
/// different languages' models can't be compared, so detecting a language per text would make
/// any passage with foreign names (a trip to Sintra, a colleague named Graça) unsearchable.
final class TextEmbedder {
    struct Embedding {
        let vector: [Float]
        /// Which language model produced the vector.
        let language: String
    }

    private let model: NLEmbedding?
    /// The language every vector is produced in.
    let language: String

    init() {
        let preferred = Locale.current.language.languageCode.map { NLLanguage($0.identifier) }
        let candidates = [preferred, .english].compactMap { $0 }
        let chosen = candidates.lazy.compactMap { language in
            NLEmbedding.sentenceEmbedding(for: language).map { (language, $0) }
        }.first
        model = chosen?.1
        language = (chosen?.0 ?? .english).rawValue
    }

    func embed(_ text: String) -> Embedding? {
        guard let model, let vector = model.vector(for: text) else { return nil }
        return Embedding(vector: Self.normalized(vector), language: language)
    }

    private static func normalized(_ vector: [Double]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard length > 0 else { return vector.map(Float.init) }
        return vector.map { Float($0 / length) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count else { return 0 }
        var sum: Float = 0
        for index in a.indices { sum += a[index] * b[index] }
        return Double(sum)
    }
}
