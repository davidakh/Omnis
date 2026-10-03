import Foundation
import SwiftData

/// Owns the SwiftData container and keeps the sessions and chats lists the UI shows.
/// Every mutation goes through here, saves, and refreshes the lists.
@Observable
final class SessionStore {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    /// Newest first.
    private(set) var sessions: [Session] = []
    private(set) var chats: [Session] = []

    init(inMemory: Bool = false) {
        let schema = Schema([Session.self, TranscriptLine.self, IndexChunk.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        do {
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Couldn't open the session store: \(error)")
        }
        if !inMemory { removeSampleData() }
        reload()
    }

    /// Earlier development builds seeded sample sessions and chats. Removes exactly those, once:
    /// sample sessions kept their seeded titles (marked custom so they were never retitled), and
    /// sample chats had no turns. Anything the user created is left alone.
    private func removeSampleData() {
        let key = "store.removedSampleData"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let sampleSessions: Set<String> = [
            "Onboarding launch sync", "Call with Roy", "Quarterly report review", "Lisbon trip planning"
        ]
        let sampleChats: Set<String> = ["Swift concurrency", "Recipe swap", "Gift ideas", "Workout plan"]

        for session in (try? context.fetch(FetchDescriptor<Session>())) ?? [] {
            let isSampleSession = session.kind == .session && session.hasCustomTitle && sampleSessions.contains(session.title)
            let isSampleChat = session.kind == .chat && session.lines.isEmpty && sampleChats.contains(session.title)
            if isSampleSession || isSampleChat { context.delete(session) }
        }
        try? context.save()
        UserDefaults.standard.set(true, forKey: key)
    }

    func reload() {
        sessions = fetch(.session)
        chats = fetch(.chat)
    }

    private func fetch(_ kind: Session.Kind) -> [Session] {
        let raw = kind.rawValue
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.kindRaw == raw },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func session(withID id: UUID) -> Session? {
        let descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    /// All sessions (not chats) still waiting for a summary or index.
    func unprocessedSessions() -> [Session] {
        sessions.filter { !$0.isProcessed && !$0.lines.isEmpty }
    }

    // MARK: - Mutations

    /// Saves a finished live session.
    @discardableResult
    func createSession(
        startedAt: Date,
        lines: [LiveLine],
        audioFolder: String? = nil,
        chats: [SessionChat] = []
    ) -> Session {
        let session = Session(
            title: String(localized: "New Session"),
            kind: .session,
            createdAt: startedAt,
            endedAt: .now
        )
        session.audioFolder = audioFolder
        session.chats = chats
        context.insert(session)
        for (order, line) in lines.enumerated() {
            let record = TranscriptLine(order: order, speaker: line.speaker, text: line.text, offset: line.offset)
            record.session = session
            context.insert(record)
        }
        save()
        return session
    }

    /// Adds one question / answer turn to a chat, creating the chat on its first turn.
    /// Returns the chat's id so follow-ups land in the same chat.
    @discardableResult
    func recordChatTurn(chatID: UUID?, question: String, answer: String) -> UUID {
        let chat: Session
        if let chatID, let existing = session(withID: chatID) {
            chat = existing
        } else {
            chat = Session(title: question, kind: .chat, isProcessed: true)
            context.insert(chat)
        }
        let offset = Date.now.timeIntervalSince(chat.createdAt)
        let next = chat.lines.count
        for (index, (speaker, text)) in [("You", question), ("Omnis", answer)].enumerated() {
            let line = TranscriptLine(order: next + index, speaker: speaker, text: text, offset: offset)
            line.session = chat
            context.insert(line)
        }
        save()
        return chat.id
    }

    /// Applies a generated title, unless the user has renamed the session or chat themselves.
    func setGeneratedTitle(_ title: String, for id: UUID) {
        guard let session = session(withID: id), !session.hasCustomTitle else { return }
        session.title = title
        save()
    }

    func rename(_ id: UUID, to title: String) {
        guard let session = session(withID: id) else { return }
        session.title = title
        session.hasCustomTitle = true
        save()
    }

    func delete(_ ids: Set<UUID>) {
        for id in ids {
            guard let session = session(withID: id) else { continue }
            // The recording goes with it.
            if let folder = session.audioFolder { AudioStorage.delete(folder) }
            context.delete(session)
        }
        save()
    }

    func save() {
        do {
            try context.save()
        } catch {
            assertionFailure("Couldn't save the session store: \(error)")
        }
        reload()
    }
}
