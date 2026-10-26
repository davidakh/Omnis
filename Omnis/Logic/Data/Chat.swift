import Foundation
import SwiftData

/// A saved conversation: its question / answer turns, in order.
@Model
final class Chat {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    /// When the last turn was added, so the list shows the latest conversations first.
    var updatedAt: Date
    /// Set once the user renames the chat, so generated titles never overwrite theirs.
    var hasCustomTitle: Bool
    /// A summary of the chat's first `summarizedTurns` turns, written once it grew long, so
    /// answers keep knowing what was said in them. Empty until then.
    var summary: String = ""
    var summarizedTurns: Int = 0

    @Relationship(deleteRule: .cascade, inverse: \ChatTurn.chat)
    var turns: [ChatTurn] = []

    init(id: UUID = UUID(), title: String, createdAt: Date = .now) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.hasCustomTitle = false
    }

    var orderedTurns: [ChatTurn] { turns.sorted { $0.order < $1.order } }

    /// Short list label: the time today, "Yesterday", a weekday this week, else a date.
    var time: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(updatedAt) {
            return updatedAt.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(updatedAt) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: updatedAt, to: .now).day, days < 7 {
            return updatedAt.formatted(.dateTime.weekday(.abbreviated))
        }
        return updatedAt.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The conversation as plain text for sharing: each question, then its answer.
    var shareText: String {
        orderedTurns
            .map { "\(String(localized: "You")): \($0.question)\n\nOmnis: \($0.answer)" }
            .joined(separator: "\n\n")
    }

    /// Whether the title or any turn contains `query` (case- and diacritic-insensitive).
    func matches(_ query: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if title.range(of: query, options: options) != nil { return true }
        return turns.contains {
            $0.question.range(of: query, options: options) != nil
                || $0.answer.range(of: query, options: options) != nil
        }
    }
}

/// One question and its answer in a saved chat.
@Model
final class ChatTurn {
    var order: Int
    var question: String
    var answer: String
    var askedAt: Date
    var chat: Chat?

    init(order: Int, question: String, answer: String, askedAt: Date = .now) {
        self.order = order
        self.question = question
        self.answer = answer
        self.askedAt = askedAt
    }
}
