import AVFoundation

/// Plays a session's recording: the mic and call-audio files mixed into one track whose
/// timeline matches the transcript's timestamps, so sections and transcript lines can be
/// jumped to by their time.
@Observable
final class SessionPlayer {
    /// The session loaded, if any.
    private(set) var sessionID: UUID?
    /// Whether the loaded session has audio to play.
    private(set) var isAvailable = false
    private(set) var isPlaying = false
    /// Becomes true on first play, and stays so (the card keeps its progress and controls).
    private(set) var hasStarted = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endTask: Task<Void, Never>?

    var progress: Double {
        duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
    }

    /// Loads `session`'s recording, unless it's already loaded.
    func load(_ session: Session) async {
        guard sessionID != session.id else { return }
        unload()
        sessionID = session.id
        guard let folder = session.audioFolder,
              let item = await Self.playerItem(folder: folder),
              sessionID == session.id else { return }

        let player = AVPlayer(playerItem: item)
        self.player = player
        duration = item.asset.duration.seconds.isFinite ? item.asset.duration.seconds : 0
        isAvailable = duration > 0

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.currentTime = time.seconds }
        }
        endTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
                self?.isPlaying = false
            }
        }
    }

    func unload() {
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        endTask?.cancel()
        player = nil
        timeObserver = nil
        endTask = nil
        sessionID = nil
        isAvailable = false
        isPlaying = false
        hasStarted = false
        currentTime = 0
        duration = 0
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player, isAvailable else { return }
        // Starting again from the end replays from the start.
        if currentTime >= duration - 0.5 { seek(to: 0) }
        player.play()
        isPlaying = true
        hasStarted = true
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func seek(to time: TimeInterval) {
        let clamped = min(max(time, 0), duration)
        currentTime = clamped
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    /// Jumps to `time` and plays from there (a section or a transcript line).
    func play(from time: TimeInterval) {
        seek(to: time)
        play()
    }

    // MARK: - Building the track

    /// Both streams placed on the session's timeline: each file starts at the moment it began
    /// recording, relative to the session's start.
    private static func playerItem(folder: String) async -> AVPlayerItem? {
        let directory = AudioStorage.url(for: folder)
        let timing = AudioStorage.timing(in: folder)
        let composition = AVMutableComposition()
        var hasAudio = false

        for (name, start) in [(AudioStorage.microphoneFile, timing.microphone), (AudioStorage.systemFile, timing.system)] {
            let url = directory.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await track.load(.timeRange),
                  range.duration.seconds > 0,
                  let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            let at = CMTime(seconds: start ?? 0, preferredTimescale: 600)
            if (try? destination.insertTimeRange(range, of: track, at: at)) != nil { hasAudio = true }
        }
        return hasAudio ? AVPlayerItem(asset: composition) : nil
    }
}
