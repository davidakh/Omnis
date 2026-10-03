import AVFoundation
import CoreGraphics
import Foundation
import Speech

/// Turns a recording session into transcript lines: captures the microphone ("You") and the
/// Mac's audio output ("Others") and transcribes each on device, feeding `LiveRecorder`.
///
/// With Screen Recording allowed, one ScreenCaptureKit stream delivers both. Without it,
/// only the microphone is recorded (through AVAudioEngine) and the recorder says so.
final class LiveTranscriber {
    static let you = String(localized: "You")
    static let others = String(localized: "Others")

    private let recorder: LiveRecorder
    private var pipelines: [AudioSource: TranscriptionPipeline] = [:]
    private var resultTasks: [Task<Void, Never>] = []
    private var systemCapture: SystemAudioCapture?
    private var microphoneCapture: MicrophoneCapture?
    private var startTask: Task<Void, Never>?

    init(recorder: LiveRecorder) {
        self.recorder = recorder
    }

    // MARK: - Lifecycle

    func start() {
        startTask = Task { await begin() }
    }

    func setPaused(_ paused: Bool) {
        for pipeline in pipelines.values { pipeline.setPaused(paused) }
        if paused {
            recorder.setPartial(speaker: Self.you, text: "")
            recorder.setPartial(speaker: Self.others, text: "")
        }
    }

    /// Stops capturing and waits for the last words to be transcribed.
    func stop() async {
        startTask?.cancel()
        await startTask?.value
        startTask = nil

        await systemCapture?.stop()
        microphoneCapture?.stop()
        systemCapture = nil
        microphoneCapture = nil

        for pipeline in pipelines.values { await pipeline.finish() }
        for task in resultTasks { await task.value }
        pipelines = [:]
        resultTasks = []
    }

    // MARK: - Starting

    private func begin() async {
        recorder.status = String(localized: "Getting ready")

        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        // Asks at most once per launch; a grant takes effect from the next session.
        let screenAllowed = ScreenRecordingPermission.ensure()
        guard microphoneAllowed || screenAllowed else {
            recorder.status = String(localized: "Allow Omnis to use the microphone in Privacy & Security to record sessions.")
            return
        }

        guard let locale = await TranscriptionPipeline.supportedLocale() else {
            recorder.status = TranscriptionError.unsupportedLocale.localizedDescription
            return
        }
        do {
            if await TranscriptionPipeline.needsAssets(for: locale) {
                recorder.status = String(localized: "Downloading the speech model")
            }
            try await TranscriptionPipeline.installAssets(for: locale)
            guard !Task.isCancelled else { return }

            // One pipeline per audio stream, so lines can be attributed to You or Others.
            var sources: [AudioSource] = []
            if microphoneAllowed { sources.append(.microphone) }
            if screenAllowed { sources.append(.system) }
            for source in sources {
                do {
                    let pipeline = try await TranscriptionPipeline.start(locale: locale)
                    pipelines[source] = pipeline
                    listen(to: pipeline, as: source)
                } catch where !pipelines.isEmpty {
                    // The system caps simultaneous transcriptions; one stream is better than none.
                    break
                }
            }
            guard !Task.isCancelled else { return }

            try await startCapture(screenAllowed: screenAllowed, microphoneAllowed: microphoneAllowed)
            recorder.status = nil
            if !screenAllowed || pipelines[.system] == nil {
                recorder.notice = String(localized: "Recording your mic only. Allow Screen Recording to include call audio.")
            } else if !microphoneAllowed {
                recorder.notice = String(localized: "Recording call audio only. Allow the microphone to include your voice.")
            }
        } catch {
            recorder.status = String(localized: "Couldn't start transcription: \(error.localizedDescription)")
        }
    }

    private func startCapture(screenAllowed: Bool, microphoneAllowed: Bool) async throws {
        let pipelines = self.pipelines
        let deliver: @Sendable (AVAudioPCMBuffer, AudioSource) -> Void = { buffer, source in
            pipelines[source]?.append(buffer)
        }

        if screenAllowed, pipelines[.system] != nil {
            let capture = SystemAudioCapture(handler: deliver)
            do {
                try await capture.start(includeMicrophone: microphoneAllowed && pipelines[.microphone] != nil)
                systemCapture = capture
                return
            } catch where microphoneAllowed && pipelines[.microphone] != nil {
                // Fall through to microphone-only capture.
            }
        }
        let microphone = MicrophoneCapture(handler: deliver)
        try microphone.start()
        microphoneCapture = microphone
    }

    // MARK: - Results

    private func listen(to pipeline: TranscriptionPipeline, as source: AudioSource) {
        let speaker = source == .microphone ? Self.you : Self.others
        let task = Task { [weak self] in
            do {
                for try await result in pipeline.transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let self else { return }
                    if result.isFinal {
                        self.finish(text, speaker: speaker, duration: result.range.duration.seconds)
                    } else {
                        self.recorder.setPartial(speaker: speaker, text: text)
                    }
                }
            } catch {
                // The stream ended with an error; whatever was finalized is kept.
            }
        }
        resultTasks.append(task)
    }

    private func finish(_ text: String, speaker: String, duration: TimeInterval) {
        guard !text.isEmpty else {
            recorder.setPartial(speaker: speaker, text: "")
            return
        }
        // Without headphones the mic also hears the call. Drop "You" lines that repeat what
        // "Others" just said.
        if speaker == Self.you, isEcho(text) {
            recorder.setPartial(speaker: speaker, text: "")
            return
        }
        recorder.append(speaker: speaker, text: text, duration: duration.isFinite ? duration : 0)
    }

    private func isEcho(_ text: String) -> Bool {
        guard pipelines[.system] != nil, let startedAt = recorder.startedAt else { return false }
        let words = Self.words(text)
        guard words.count >= 3 else { return false }
        let now = Date.now.timeIntervalSince(startedAt)
        return recorder.lines.reversed()
            .prefix { now - $0.offset < 20 }
            .contains { line in
                guard line.speaker == Self.others else { return false }
                let other = Self.words(line.text)
                let shared = words.intersection(other).count
                return Double(shared) / Double(max(words.count, 1)) >= 0.6
            }
    }

    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}
