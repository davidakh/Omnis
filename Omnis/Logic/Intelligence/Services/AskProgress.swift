import Foundation
import Synchronization

/// An estimate of how far along an answer is, for the percentage beside its status.
///
/// Each step sets where it's heading and about how long it takes. The estimate eases toward
/// there, slowing as it nears, so it keeps moving during a long wait without ever reaching 100%
/// before the first word. Starting a step means the last one is done, so it catches up first.
nonisolated final class AskProgress: Sendable {
    private struct State {
        var value = 0.0
        var target = 0.0
        /// Seconds to cover most of the way to the target.
        var seconds = 1.0
        var reported = -1
        var stopped = false
    }

    private enum Tick { case stop, unchanged, report(Int) }

    private let state = Mutex(State())

    /// Heads toward `fraction` (0…1) over about `seconds`.
    func advance(to fraction: Double, over seconds: Double) {
        state.withLock {
            $0.value = max($0.value, $0.target)
            $0.target = max($0.target, fraction)
            $0.seconds = max(0.2, seconds)
        }
    }

    /// The answer has started: no more percentages.
    func stop() {
        state.withLock { $0.stopped = true }
    }

    /// Reports each new whole percent until stopped or cancelled.
    func run(into continuation: AsyncThrowingStream<AskEvent, Error>.Continuation) -> Task<Void, Never> {
        Task {
            var last = Date.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                let now = Date.now
                let elapsed = now.timeIntervalSince(last)
                last = now
                let tick: Tick = state.withLock { state in
                    guard !state.stopped else { return .stop }
                    // Exponential approach: about 86% of the remaining way in `seconds`.
                    state.value += (state.target - state.value) * (1 - exp(-elapsed * 2 / state.seconds))
                    let percent = Int(state.value * 100)
                    guard percent > state.reported else { return .unchanged }
                    state.reported = percent
                    return .report(percent)
                }
                switch tick {
                case .stop: return
                case .unchanged: continue
                case .report(let percent): continuation.yield(.progress(percent))
                }
            }
        }
    }
}
