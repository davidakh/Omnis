import SwiftUI

enum SurfaceMetrics {
    static let maxSize = CGSize(width: 560, height: 480)
    static let minSide: CGFloat = 56           // compact capsule height
    static let maxCornerRadius: CGFloat = 28   // = minSide / 2, so a short surface is a perfect capsule
    static let overshootMargin: CGFloat = 24   // room for spring overshoot inside the panel
    static let dockGap: CGFloat = 12           // gap between the glass and the top of the Dock

    /// The panel never resizes; it always has room for the largest surface plus overshoot.
    static var panelSize: CGSize {
        CGSize(width: maxSize.width + overshootMargin * 2, height: maxSize.height + overshootMargin * 2)
    }
}

enum SurfaceMotion {
    static let spillLead = Animation.spring(duration: 0.42, bounce: 0.26)
    static let spillFollow = Animation.spring(duration: 0.58, bounce: 0.34)
    static let drainLead = Animation.spring(duration: 0.40, bounce: 0.18)
    static let drainFollow = Animation.spring(duration: 0.52, bounce: 0.30)
    static let lag: TimeInterval = 0.07
    static let content = Animation.smooth(duration: 0.32)
    static let materialize = Animation.spring(duration: 0.40, bounce: 0.18)
    static let minimumSqueeze: CGFloat = 0.8
    static let morphBlur: CGFloat = 10
    static let morphBlurRange: CGFloat = 60
}
