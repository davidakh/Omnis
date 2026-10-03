#if DEBUG
import Foundation
import SwiftData

/// Development content: on a first launch with an empty store, fills it with sample sessions
/// and chats so every screen (and the index) has something to show. Seeded sessions arrive
/// unprocessed, so they go through the same summary and indexing pipeline as real ones.
enum MockData {
    static func seedIfEmpty(_ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<Session>())) ?? 0
        guard count == 0 else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func date(daysAgo: Int, hour: Int, minute: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        for sample in sessions {
            let start = date(daysAgo: sample.daysAgo, hour: sample.hour, minute: sample.minute)
            let session = Session(title: sample.title, kind: .session, createdAt: start, endedAt: start + 1800)
            session.hasCustomTitle = true  // keep the sample titles; only the summary is generated
            context.insert(session)
            for (order, line) in sample.lines.enumerated() {
                let record = TranscriptLine(order: order, speaker: line.speaker, text: line.text, offset: TimeInterval(order * 20))
                record.session = session
                context.insert(record)
            }
        }

        for (index, title) in chatTitles.enumerated() {
            let chat = Session(title: title, kind: .chat, createdAt: date(daysAgo: index, hour: 10, minute: 2), isProcessed: true)
            context.insert(chat)
        }

        try? context.save()
    }

    private struct Sample {
        let title: String
        let daysAgo: Int
        let hour: Int
        let minute: Int
        let lines: [(speaker: String, text: String)]
    }

    private static let sessions: [Sample] = [
        Sample(title: "Onboarding launch sync", daysAgo: 0, hour: 9, minute: 12, lines: [
            ("Maya", "Okay, let's get started. Thanks for joining, everyone."),
            ("Maya", "The main thing today is the launch timeline for the new onboarding flow."),
            ("Sam", "Design is basically done. We're waiting on the final copy for the welcome screens."),
            ("Maya", "When do we expect the copy?"),
            ("Sam", "End of this week, hopefully Thursday."),
            ("Priya", "Engineering can start on the screens that are locked. The welcome copy won't block us."),
            ("Maya", "Great. So what's the realistic ship date?"),
            ("Priya", "If QA gets a build by the 14th, we can ship the following Tuesday."),
            ("Sam", "I'd add a buffer for the accessibility review. It caught a lot last time."),
            ("Maya", "Fair. Let's plan on the 21st and treat the 18th as a stretch goal."),
            ("Priya", "Works for me. I'll update the tracker after this."),
            ("Maya", "And we should loop in support before launch so they're ready for questions.")
        ]),
        Sample(title: "Call with Roy", daysAgo: 1, hour: 15, minute: 30, lines: [
            ("Roy", "Thanks for making time. I wanted to walk you through the open roles on my team."),
            ("Roy", "We have two openings right now: a product designer and a Swift engineer."),
            ("You", "Have you considered combining them? A design-to-code role could work with Dimitri on design and the dev team on the front end."),
            ("Roy", "That's interesting. I'd need to check with the hiring manager whether we can scope it that way."),
            ("You", "Happy to share a few portfolio pieces that show both sides."),
            ("Roy", "Please do, two or three would be great."),
            ("Roy", "If the role works out, I'd like to set up a follow-up interview with the hiring manager."),
            ("Roy", "Let's aim for the week of the 12th. I'll email you some time slots.")
        ]),
        Sample(title: "Quarterly report review", daysAgo: 3, hour: 11, minute: 0, lines: [
            ("You", "Let's go through where things stand for the quarterly report."),
            ("Dana", "Revenue is up eight percent quarter over quarter, mostly from the new enterprise tier."),
            ("You", "What about churn?"),
            ("Dana", "Churn ticked up slightly in the self-serve plan. Pricing feedback is the top reason."),
            ("You", "Two things are still blocked, right?"),
            ("Dana", "Yes, the budget sign-off and the design review. Both were due yesterday."),
            ("You", "I'll chase those today. Let's finish the draft and confirm the timeline before Thursday."),
            ("Dana", "Sounds right. Everything else can move to the backlog.")
        ]),
        Sample(title: "Lisbon trip planning", daysAgo: 6, hour: 19, minute: 45, lines: [
            ("You", "We land in Lisbon on Friday the 9th around noon."),
            ("Alex", "The apartment in Alfama is booked through Monday."),
            ("You", "Let's do the tram 28 ride Saturday morning before it gets crowded."),
            ("Alex", "And dinner Saturday at the place near Miradouro da Graça, I'll book for eight."),
            ("You", "Sunday could be a day trip to Sintra. Trains leave from Rossio every twenty minutes."),
            ("Alex", "Perfect. I'll buy the Pena Palace tickets online so we skip the line.")
        ])
    ]

    private static let chatTitles = [
        "Swift concurrency",
        "Recipe swap",
        "Gift ideas",
        "Workout plan"
    ]
}
#endif
