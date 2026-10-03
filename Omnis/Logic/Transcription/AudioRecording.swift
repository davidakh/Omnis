// Buffers are freshly copied per callback and handed off, never shared (see AudioBuffers).
@preconcurrency import AVFAudio
import Foundation

/// Where recorded session audio lives: one folder per session inside the app's container,
/// holding a compressed file per stream and their timing.
nonisolated enum AudioStorage {
    static let microphoneFile = "microphone.m4a"
    static let systemFile = "system.m4a"
    static let timingFile = "timing.json"

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
    }

    static func url(for folder: String) -> URL {
        directory.appending(path: folder, directoryHint: .isDirectory)
    }

    /// A fresh, empty folder for a new recording.
    static func makeFolder() -> String {
        let name = UUID().uuidString
        try? FileManager.default.createDirectory(at: url(for: name), withIntermediateDirectories: true)
        return name
    }

    static func delete(_ folder: String) {
        try? FileManager.default.removeItem(at: url(for: folder))
    }

    static func timing(in folder: String) -> AudioTiming {
        let url = url(for: folder).appending(path: timingFile)
        guard let data = try? Data(contentsOf: url),
              let timing = try? JSONDecoder().decode(AudioTiming.self, from: data) else { return AudioTiming() }
        return timing
    }
}

/// When each stream's file starts, in seconds after the session started, so playback lines up
/// with transcript timestamps.
nonisolated struct AudioTiming: Codable, Sendable {
    var microphone: Double?
    var system: Double?
}

/// Writes a recording's audio to disk as it's captured: each stream to its own AAC file, about
/// 15 MB an hour each. While paused, silence is written instead, so the files keep the same
/// timeline as the transcript.
nonisolated final class AudioFileWriter: @unchecked Sendable {
    private let folder: URL
    private let startedAt: Date
    private let queue = DispatchQueue(label: "Omnis.recording.write")

    // Only touched on `queue`.
    private var files: [AudioSource: AVAudioFile] = [:]
    private var converters: [AudioSource: AVAudioConverter] = [:]
    private var timing = AudioTiming()
    private var isPaused = false
    private var isFinished = false

    init(folder: URL, startedAt: Date) {
        self.folder = folder
        self.startedAt = startedAt
    }

    /// - Parameter silent: write silence instead (the source is turned off), so the file keeps
    ///   the session's timeline.
    func append(_ buffer: AVAudioPCMBuffer, from source: AudioSource, silent: Bool = false) {
        queue.async { [self] in
            guard !isFinished, buffer.frameLength > 0 else { return }
            do {
                let file = try file(for: source, matching: buffer.format)
                guard let output = convert(buffer, to: file.processingFormat, source: source) else { return }
                if isPaused || silent { Self.silence(output) }
                try file.write(from: output)
            } catch {
                // A buffer that can't be written is dropped; the recording carries on.
            }
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [self] in isPaused = paused }
    }

    /// Closes the files (finalizing them so they play) and saves their timing. Waits for writes
    /// already queued.
    func finish() {
        queue.sync { [self] in
            guard !isFinished else { return }
            isFinished = true
            for file in files.values { file.close() }
            files = [:]
            if let data = try? JSONEncoder().encode(timing) {
                try? data.write(to: folder.appending(path: AudioStorage.timingFile))
            }
        }
    }

    // MARK: - Files

    private func file(for source: AudioSource, matching format: AVAudioFormat) throws -> AVAudioFile {
        if let file = files[source] { return file }
        let channels = min(format.channelCount, 2)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 32_000 * Int(channels)
        ]
        let name = source == .microphone ? AudioStorage.microphoneFile : AudioStorage.systemFile
        let file = try AVAudioFile(
            forWriting: folder.appending(path: name),
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        files[source] = file
        let offset = max(0, Date.now.timeIntervalSince(startedAt))
        switch source {
        case .microphone: timing.microphone = offset
        case .system: timing.system = offset
        }
        return file
    }

    /// Converts to the file's format when the capture format differs (e.g. interleaved).
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat, source: AudioSource) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard buffer.format.sampleRate == format.sampleRate else { return nil }  // a device change mid-session
        let converter: AVAudioConverter
        if let existing = converters[source], existing.inputFormat == buffer.format {
            converter = existing
        } else if let made = AVAudioConverter(from: buffer.format, to: format) {
            converter = made
            converters[source] = made
        } else {
            return nil
        }
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else { return nil }
        do {
            try converter.convert(to: output, from: buffer)
            return output
        } catch {
            return nil
        }
    }

    private static func silence(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            channels[channel].update(repeating: 0, count: Int(buffer.frameLength))
        }
    }
}
