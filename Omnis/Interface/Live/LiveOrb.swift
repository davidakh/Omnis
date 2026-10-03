import SwiftUI

// MARK: - Live orb

/// The live session's orb: tap to pause / resume, hold to end. While held, the orb morphs to
/// its gauge ring, which fills over `holdFill`; releasing early springs it back.
struct LiveOrb: View {
    let state: AppState
    let diameter: CGFloat

    @State private var pressStart: Date?
    @State private var holdingSince: Date?
    @State private var holdTask: Task<Void, Never>?
    @State private var ended = false

    private static var tapWindow: TimeInterval { 0.2 }  // released sooner than this is a tap
    private static var holdFill: TimeInterval { 0.9 }   // gauge fill time; when full, the session ends

    var body: some View {
        SurfaceOrb(animation: state.orb, diameter: diameter) { date in
            guard let holdingSince else { return 0 }
            return min(max(date.timeIntervalSince(holdingSince) / Self.holdFill, 0), 1)
        }
        .glassEffect(.clear.interactive(), in: Circle())
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressBegan() }
                .onEnded { _ in pressEnded() }
        )
    }

    private func pressBegan() {
        guard pressStart == nil, !ended else { return }
        pressStart = .now
        holdTask = Task {
            try? await Task.sleep(for: .seconds(Self.tapWindow))
            guard !Task.isCancelled else { return }
            holdingSince = .now
            state.setOrbShape(.gauge)
            try? await Task.sleep(for: .seconds(Self.holdFill))
            guard !Task.isCancelled else { return }
            ended = true
            state.endSession()
        }
    }

    private func pressEnded() {
        holdTask?.cancel()
        defer {
            pressStart = nil
            holdingSince = nil
        }
        guard !ended else { return }
        if holdingSince != nil {
            // Let go before the gauge filled: back to recording (or paused).
            state.setOrbShape(state.isPaused ? .circle : .square)
        } else if pressStart != nil {
            state.togglePause()
        }
    }
}
