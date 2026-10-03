// Buffers are freshly copied per callback and handed off, never shared (see AudioBuffers).
@preconcurrency import AVFAudio
import CoreMedia
import ScreenCaptureKit

/// Where a piece of captured audio came from.
nonisolated enum AudioSource: Sendable {
    /// The user's microphone: "You".
    case microphone
    /// What the Mac plays (call participants, videos): "Others".
    case system
}

/// Captures system audio and the microphone together through one ScreenCaptureKit stream.
/// Needs the Screen Recording permission (and Microphone for the mic half).
nonisolated final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let handler: @Sendable (AVAudioPCMBuffer, AudioSource) -> Void
    private let queue = DispatchQueue(label: "Omnis.capture.audio")
    private var stream: SCStream?
    /// Called if capture stops on its own (e.g. a permission is revoked).
    var onStop: (@Sendable (Error) -> Void)?

    init(handler: @escaping @Sendable (AVAudioPCMBuffer, AudioSource) -> Void) {
        self.handler = handler
    }

    func start(includeMicrophone: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw ScreenCaptureError.noWindow }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = includeMicrophone
        // Audio is all that's wanted: keep the unavoidable video stream tiny and rare.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        // A screen output is added only so ScreenCaptureKit doesn't log dropped video frames.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if includeMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        let source: AudioSource
        switch type {
        case .audio: source = .system
        case .microphone: source = .microphone
        default: return
        }
        if let buffer = AudioBuffers.pcm(from: sampleBuffer) { handler(buffer, source) }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onStop?(error)
    }
}

/// Microphone only, through AVAudioEngine. Used when Screen Recording isn't granted, so a
/// session can still be recorded (without the other side of a call).
nonisolated final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let handler: @Sendable (AVAudioPCMBuffer, AudioSource) -> Void

    init(handler: @escaping @Sendable (AVAudioPCMBuffer, AudioSource) -> Void) {
        self.handler = handler
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        try input.installAudioTap(onBus: 0, bufferSize: 4096, format: format) { [handler] buffer, _ in
            // The transcriber may hold onto audio between calls, so it gets its own copy.
            handler(AVAudioPCMBuffer(copying: buffer), .microphone)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

nonisolated enum AudioBuffers {
    /// Copies a captured sample buffer's audio into a standalone PCM buffer.
    static func pcm(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard var description = sampleBuffer.formatDescription?.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &description) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        do {
            try sampleBuffer.copyPCMData(fromRange: 0..<sampleBuffer.numSamples, into: buffer.mutableAudioBufferList)
        } catch {
            return nil
        }
        return buffer
    }
}
