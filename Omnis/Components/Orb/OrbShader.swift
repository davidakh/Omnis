import SwiftUI

enum OrbShader {
    static let scale: CGFloat = 2.5

    static func fluidDots(
        extent: CGFloat,
        phase: Double,
        gather: Double,
        opacity: Double,
        gaugeMix: Double,
        squareMix: Double,
        circleMix: Double = 0,
        progress: Double
    ) -> Shader {
        ShaderLibrary.fluidDotsOrb(
            .float2(Float(extent), Float(extent)),
            .float(Float(phase)),
            .float(Float(gather)),
            .float(Float(opacity)),
            .float(Float(1.0 / scale)),
            .float(Float(gaugeMix)),
            .float(Float(squareMix)),
            .float(Float(circleMix)),
            .float(Float(progress))
        )
    }

    static func warmUp() async {
        let probe = fluidDots(
            extent: 1,
            phase: 0,
            gather: OrbAnimation.noGather,
            opacity: 1,
            gaugeMix: 0,
            squareMix: 0,
            progress: 0
        )
        try? await probe.compile(as: .shapeStyle)
    }
}
