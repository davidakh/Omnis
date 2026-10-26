import Foundation
import SwiftData

/// Owns the SwiftData container and keeps the chats list the UI shows. Every mutation goes
/// through here, saves, and refreshes the list.
@Observable
final class ChatStore {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    /// Most recently updated first.
    private(set) var chats: [Chat] = []

    init(inMemory: Bool = false) {
        let schema = Schema([Chat.self, ChatTurn.self])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            // Its own file, apart from the store earlier builds kept sessions in.
            let folder = URL.applicationSupportDirectory.appending(path: "Omnis", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: folder.appending(path: "Chats.store"))
        }
        do {
            container = try ModelContainer(for: schema, configurations: configuration)
        } catch {
            fatalError("Couldn't open the chat store: \(error)")
        }
        reload()
    }

    func reload() {
        let descriptor = FetchDescriptor<Chat>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        chats = (try? context.fetch(descriptor)) ?? []
    }

    func chat(withID id: UUID) -> Chat? {
        let descriptor = FetchDescriptor<Chat>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    // MARK: - Mutations

    /// Adds one question / answer turn to a chat, creating the chat on its first turn.
    /// Returns the chat's id so follow-ups land in the same chat.
    @discardableResult
    func recordTurn(chatID: UUID?, question: String, answer: String) -> UUID {
        let chat: Chat
        if let chatID, let existing = self.chat(withID: chatID) {
            chat = existing
        } else {
            chat = Chat(title: question)
            context.insert(chat)
        }
        let turn = ChatTurn(order: chat.turns.count, question: question, answer: answer)
        turn.chat = chat
        context.insert(turn)
        chat.updatedAt = .now
        save()
        return chat.id
    }

    /// Applies a generated title, unless the user has renamed the chat themselves.
    func setGeneratedTitle(_ title: String, for id: UUID) {
        guard let chat = chat(withID: id), !chat.hasCustomTitle else { return }
        chat.title = title
        save()
    }

    /// Keeps the summary of a chat's earlier turns, so it's there when the chat is reopened.
    func setMemory(_ memory: ConversationMemory, for id: UUID) {
        guard let chat = chat(withID: id) else { return }
        chat.summary = memory.summary
        chat.summarizedTurns = memory.coveredTurns
        save()
    }

    func rename(_ id: UUID, to title: String) {
        guard let chat = chat(withID: id) else { return }
        chat.title = title
        chat.hasCustomTitle = true
        save()
    }

    func delete(_ ids: Set<UUID>) {
        for id in ids {
            if let chat = chat(withID: id) { context.delete(chat) }
        }
        save()
    }

    func save() {
        do {
            try context.save()
        } catch {
            assertionFailure("Couldn't save the chat store: \(error)")
        }
        reload()
    }
}
