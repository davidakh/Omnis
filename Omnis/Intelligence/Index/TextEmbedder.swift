import NaturalLanguage

/// On-device sentence embeddings from NaturalLanguage, one model per language, loaded lazily.
/// Vectors are L2-normalized, so cosine similarity is a dot product.
final class TextEmbedder {
    private var embeddings: [NLLanguage: NLEmbedding] = [:]
    private var unavailable: Set<NLLanguage> = []

    struct Embedding {
        let vector: [Float]
        /// Vectors from different languages' models aren't comparable.
        let language: String
    }

    func embed(_ text: String) -> Embedding? {
        let detected = dominantLanguage(of: text)
        for language in [detected, .english] {
            guard let model = model(for: language), let vector = model.vector(for: text) else { continue }
            return Embedding(vector: Self.normalized(vector), language: language.rawValue)
        }
        return nil
    }

    private func dominantLanguage(of text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage ?? .english
    }

    private func model(for language: NLLanguage) -> NLEmbedding? {
        if let cached = embeddings[language] { return cached }
        guard !unavailable.contains(language) else { return nil }
        guard let model = NLEmbedding.sentenceEmbedding(for: language) else {
            unavailable.insert(language)
            return nil
        }
        embeddings[language] = model
        return model
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
