import SwiftUI

nonisolated enum OrbShape: Sendable {
    case dots
    case gauge
    case square
    case circle   // the small lit circle, shown while a session is paused
}

/// The fluid-dots orb (FluidDotsOrb.metal), clipped to a circle. `progress` drives the gauge
/// ring and is evaluated every frame, so callers can animate it over time.
struct SurfaceOrb: View {
    let animation: OrbAnimation
    var diameter: CGFloat
    var progress: (Date) -> Double = { _ in 0 }

    var body: some View {
        TimelineView(.animation) { context in
            let date = context.date
            let extent = diameter * OrbShader.scale
            Rectangle()
                .fill(
                    OrbShader.fluidDots(
                        extent: extent,
                        phase: animation.phase(at: date),
                        gather: animation.gather(at: date),
                        opacity: 1,
                        gaugeMix: animation.mix(for: .gauge, at: date),
                        squareMix: animation.mix(for: .square, at: date),
                        circleMix: animation.mix(for: .circle, at: date),
                        progress: progress(date)
                    )
                )
                .frame(width: extent, height: extent)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .allowsHitTesting(false)
    }
}
