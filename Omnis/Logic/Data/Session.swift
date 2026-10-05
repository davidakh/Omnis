import Foundation
import SwiftData

/// A recorded session, or a saved chat. Both keep their content as ordered transcript
/// lines: a session's are what was said, a chat's are its "You" / "Omnis" turns.
@Model
final class Session {
    enum Kind: String, Codable { case session, chat }

    @Attribute(.unique) var id: UUID
    var title: String
    /// Stored as a raw string so fetches can filter on it.
    var kindRaw: String
    var createdAt: Date
    var endedAt: Date?
    var summary: String?
    /// One sentence saying what the session is and who's in it ("A podcast interview with Emma
    /// Watson about her film work"), so a model can tell sessions apart at a glance.
    var definition: String? = nil
    /// False until the title and summary have been generated and the session indexed.
    var isProcessed: Bool
    /// Set once the user renames the session, so generated titles never overwrite theirs.
    var hasCustomTitle: Bool
    /// The folder (inside `AudioStorage.directory`) holding the session's recorded audio.
    var audioFolder: String? = nil
    /// Generated sections, JSON-encoded; read and write through `sections`.
    var sectionsData: Data? = nil
    /// Questions asked during the session, JSON-encoded; read and write through `chats`.
    var chatsData: Data? = nil
    /// Audio recorded each time the session was resumed (folders inside `AudioStorage.directory`),
    /// JSON-encoded; read and write through `resumedAudioFolders`.
    var resumedAudioData: Data? = nil
    /// The length of the session's timeline, once it has been resumed (its wall-clock span then
    /// includes the gaps between recordings, which the timeline doesn't).
    var recordedLength: TimeInterval? = nil

    @Relationship(deleteRule: .cascade, inverse: \TranscriptLine.session)
    var lines: [TranscriptLine] = []

    @Relationship(deleteRule: .cascade, inverse: \IndexChunk.session)
    var chunks: [IndexChunk] = []

    init(
        id: UUID = UUID(),
        title: String,
        kind: Kind,
        createdAt: Date = .now,
        endedAt: Date? = nil,
        summary: String? = nil,
        isProcessed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kindRaw = kind.rawValue
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.summary = summary
        self.isProcessed = isProcessed
        self.hasCustomTitle = false
    }

    var kind: Kind { Kind(rawValue: kindRaw) ?? .session }

    /// Points of interest: where the conversation moves to a new topic, in order.
    var sections: [SessionSection] {
        get { sectionsData.flatMap { try? JSONDecoder().decode([SessionSection].self, from: $0) } ?? [] }
        set { sectionsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    /// The chats asked while the session was recording, in the order they started.
    var chats: [SessionChat] {
        get { chatsData.flatMap { try? JSONDecoder().decode([SessionChat].self, from: $0) } ?? [] }
        set { chatsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    /// Recordings added by resuming the session, in order. Each one's audio is already placed on
    /// the session's timeline (its timing starts where the session had left off).
    var resumedAudioFolders: [String] {
        get { resumedAudioData.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [] }
        set { resumedAudioData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    /// Every recording of the session, first to last.
    var audioFolders: [String] { (audioFolder.map { [$0] } ?? []) + resumedAudioFolders }

    /// How long the session's timeline runs: where a resumed recording picks up.
    var length: TimeInterval {
        let spoken = (lines.map(\.offset).max() ?? 0) + 1
        if let recordedLength { return max(recordedLength, spoken) }
        if let endedAt { return max(endedAt.timeIntervalSince(createdAt), spoken) }
        return spoken
    }

    var orderedLines: [TranscriptLine] { lines.sorted { $0.order < $1.order } }

    /// The transcript as plain text, one "Speaker: text" line each.
    var transcriptText: String {
        orderedLines.map { "\($0.speaker): \($0.text)" }.joined(separator: "\n")
    }

    /// Short list label: the time today, "Yesterday", a weekday this week, else a date.
    var time: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(createdAt) {
            return createdAt.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(createdAt) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: createdAt, to: .now).day, days < 7 {
            return createdAt.formatted(.dateTime.weekday(.abbreviated))
        }
        return createdAt.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A titled part of a session, from where the conversation turns to it.
struct SessionSection: Codable, Hashable, Identifiable {
    var title: String
    /// Seconds from the start of the session.
    var start: TimeInterval

    var id: TimeInterval { start }

    /// "4:20" style, or "1:04:20" past an hour.
    var timestamp: String { Self.format(start) }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600, minutes = total % 3600 / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// A question thread asked during a live session, with its answered turns.
struct SessionChat: Codable, Hashable, Identifiable {
    struct Turn: Codable, Hashable {
        var question: String
        var answer: String
        /// Seconds from the start of the session, when the answer settled.
        var offset: TimeInterval

        var timestamp: String { SessionSection.format(offset) }
    }

    var id: UUID
    var turns: [Turn]
}

/// One line of a transcript.
@Model
final class TranscriptLine {
    var order: Int
    var speaker: String
    var text: String
    /// Seconds from the start of the session.
    var offset: TimeInterval
    var session: Session?

    init(order: Int, speaker: String, text: String, offset: TimeInterval) {
        self.order = order
        self.speaker = speaker
        self.text = text
        self.offset = offset
    }

    /// "1:41" style timestamp.
    var timestamp: String {
        let seconds = Int(offset)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A searchable slice of a session (part of its summary or transcript) with its embedding.
/// Built and queried by `SessionIndex`.
@Model
final class IndexChunk {
    enum Source: String, Codable { case summary, transcript }

    var sourceRaw: String
    var text: String
    /// Offset of the first transcript line in the chunk; nil for summary chunks.
    var startOffset: TimeInterval?
    /// Language of the embedding; vectors are only comparable within one language.
    var language: String
    /// The normalized embedding, as packed `Float`s.
    var vectorData: Data
    var session: Session?

    init(source: Source, text: String, startOffset: TimeInterval?, language: String, vector: [Float]) {
        self.sourceRaw = source.rawValue
        self.text = text
        self.startOffset = startOffset
        self.language = language
        self.vectorData = vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    var source: Source { Source(rawValue: sourceRaw) ?? .transcript }

    var vector: [Float] {
        vectorData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
