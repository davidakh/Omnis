import Foundation

nonisolated struct OrbAnimation: Sendable, Equatable {
    static let noGather: Double = -1000
    static let morphDuration: TimeInterval = 0.55
    static let phaseSpeed: Double = 1.4

    var epoch: Date
    var epochPhase: TimeInterval
    var speed: Double
    var gatherStart: Date?
    var shape: OrbShape
    var previousShape: OrbShape
    var shapeStart: Date
    var progress: Double

    init(
        epoch: Date,
        epochPhase: TimeInterval,
        speed: Double = Self.phaseSpeed,
        gatherStart: Date? = nil,
        shape: OrbShape = .dots,
        previousShape: OrbShape = .dots,
        shapeStart: Date? = nil,
        progress: Double = 0
    ) {
        self.epoch = epoch
        self.epochPhase = epochPhase
        self.speed = speed
        self.gatherStart = gatherStart
        self.shape = shape
        self.previousShape = previousShape
        self.shapeStart = shapeStart ?? epoch
        self.progress = progress
    }

    func phase(at date: Date) -> TimeInterval {
        max(0, epochPhase + date.timeIntervalSince(epoch) * speed)
    }

    func gather(at date: Date) -> Double {
        guard let gatherStart else { return Self.noGather }
        return date.timeIntervalSince(gatherStart)
    }

    func mix(for target: OrbShape, at date: Date) -> Double {
        let from: Double = previousShape == target ? 1 : 0
        let to: Double = shape == target ? 1 : 0
        guard from != to else { return to }
        return from + (to - from) * morphFraction(at: date)
    }

    private func morphFraction(at date: Date) -> Double {
        let raw = min(max(date.timeIntervalSince(shapeStart) / Self.morphDuration, 0), 1)
        return raw * raw * (3 - 2 * raw)
    }
}
