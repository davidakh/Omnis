import Foundation

/// Recognizes when something typed into the ask bar is a request to start a session ("start a
/// session", "can you record this meeting?") rather than a question for the model.
///
/// Matched by phrase rather than by the model, so it works with every provider and starts
/// recording instantly. Only requests that lead with the action count, so questions *about*
/// sessions ("how do I start a session?", "what did we say in my last session?") still go to
/// the model.
enum SessionCommand {
    static func isStartRequest(_ text: String) -> Bool {
        var request = text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.whitespaces).inverted).joined()
            .split(separator: " ").joined(separator: " ")

        // Politeness and the assistant's name in front don't change the request.
        var stripped = true
        while stripped {
            stripped = false
            for filler in fillers where request.hasPrefix(filler + " ") {
                request.removeFirst(filler.count + 1)
                stripped = true
            }
        }
        // Trailing politeness too ("start a session please").
        for filler in ["please", "now", "for me"] where request.hasSuffix(" " + filler) {
            request.removeLast(filler.count + 1)
        }

        // Short commands only, so a longer question that happens to begin the same way
        // ("start a session summary for…") isn't swallowed.
        guard request.split(separator: " ").count <= 6 else { return false }
        return requests.contains { request == $0 || request.hasPrefix($0 + " ") }
    }

    private static let fillers = [
        "hey omnis", "omnis", "ok", "okay", "please", "can you", "could you", "would you",
        "will you", "can we", "could we", "lets", "let us", "i want to", "i would like to",
        "i need to", "go ahead and", "and"
    ]

    private static let requests = [
        "start a session", "start a new session", "start session", "start new session",
        "start the session", "begin a session", "begin a new session", "begin session",
        "new session", "start recording", "begin recording", "start a recording",
        "record this", "record this meeting", "record this call", "record the meeting",
        "record the call", "record my meeting", "record my call", "record a session",
        "start listening", "start transcribing", "transcribe this"
    ]
}
