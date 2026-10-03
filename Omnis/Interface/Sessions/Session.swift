import Foundation

// MARK: - Sessions list (mock data)

struct Session: Identifiable, Hashable {
    let id = UUID()
    var title: String
    let time: String

    static let mockSessions: [Session] = [
        .init(title: "Morning planning", time: "9:12"),
        .init(title: "Quarterly report", time: "8:40"),
        .init(title: "Inbox triage", time: "Yesterday"),
        .init(title: "Offsite agenda", time: "Yesterday"),
        .init(title: "Pricing analysis", time: "Mon"),
        .init(title: "Build fixes", time: "Mon"),
        .init(title: "Lisbon trip", time: "Sun"),
        .init(title: "Reading notes", time: "Sat"),
        .init(title: "Playlist ideas", time: "Fri"),
        .init(title: "Groceries", time: "Thu"),
        .init(title: "1:1 prep", time: "Wed"),
        .init(title: "Side project", time: "Sep 28")
    ]

    static let mockChats: [Session] = [
        .init(title: "Swift concurrency", time: "10:02"),
        .init(title: "Recipe swap", time: "9:30"),
        .init(title: "Gift ideas", time: "Yesterday"),
        .init(title: "Workout plan", time: "Mon"),
        .init(title: "Spanish practice", time: "Sun"),
        .init(title: "Tax question", time: "Sat"),
        .init(title: "Bike repair", time: "Fri"),
        .init(title: "Poem draft", time: "Thu")
    ]
}
