// Audio buffers are handed off between threads (each capture callback makes a fresh copy and
// never touches it again), so AVFAudio's missing Sendable annotations don't apply here.
@preconcurrency import AVFAudio
import Speech

enum TranscriptionError: LocalizedError {
    case unsupportedLocale
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedLocale:
            String(localized: "Transcription isn't available for your language yet.")
        case .noAudioFormat:
            String(localized: "Transcription couldn't start on this Mac.")
        }
    }
}

/// One audio stream → text, on device: a `SpeechTranscriber` driven by its own
/// `SpeechAnalyzer`. Audio arrives from capture threads; results are read from `results`.
nonisolated final class TranscriptionPipeline: @unchecked Sendable {
    let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    /// Not thread-safe and may hold audio between calls, so it's only touched on `queue`.
    private let converter: AnalyzerInputConverter
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let queue = DispatchQueue(label: "Omnis.transcription.convert")
    private var isPaused = false   // read and written on `queue`

    private init(
        transcriber: SpeechTranscriber,
        analyzer: SpeechAnalyzer,
        converter: AnalyzerInputConverter,
        input: AsyncStream<AnalyzerInput>.Continuation
    ) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.converter = converter
        self.input = input
    }

    /// The transcriber configuration both pipelines share (so the system can share the model).
    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // Volatile results show words as they're spoken; final ones replace them.
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// The closest supported locale to the user's, or nil if transcription can't run here.
    static func supportedLocale() async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: .current)
    }

    /// Whether the speech model for `locale` still has to be downloaded.
    static func needsAssets(for locale: Locale) async -> Bool {
        await AssetInventory.status(forModules: [makeTranscriber(locale: locale)]) < .installed
    }

    /// Downloads the speech model if needed. Safe to call when it's already installed.
    static func installAssets(for locale: Locale) async throws {
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber(locale: locale)]) {
            try await request.downloadAndInstall()
        }
    }

    static func start(locale: Locale) async throws -> TranscriptionPipeline {
        let transcriber = makeTranscriber(locale: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)
        return TranscriptionPipeline(
            transcriber: transcriber,
            analyzer: analyzer,
            converter: AnalyzerInputConverter(analyzerFormat: format),
            input: continuation
        )
    }

    /// Feeds captured audio. Call from any thread; the buffer must not be reused afterwards.
    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard !isPaused else { return }
            do {
                for item in try converter.convert(buffer, at: nil) { input.yield(item) }
            } catch {
                // A malformed buffer is skipped; the stream carries on with the next one.
            }
        }
    }

    /// While paused, incoming audio is dropped rather than transcribed.
    func setPaused(_ paused: Bool) {
        queue.async { [self] in isPaused = paused }
    }

    /// Transcribes what's left, delivers the final results, then ends `results`.
    func finish() async {
        queue.sync { [self] in
            if let remaining = try? converter.flush() {
                for item in remaining { input.yield(item) }
            }
            input.finish()
        }
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
        }
    }

    func cancel() async {
        queue.sync { [self] in input.finish() }
        await analyzer.cancelAndFinishNow()
    }
}
