import SwiftUI

enum SurfaceMetrics {
    static let maxSize = CGSize(width: 560, height: 480)
    static let minSide: CGFloat = 48           // compact capsule height (32 pt button + 8 pt padding each side)
    static let maxCornerRadius: CGFloat = 36   // rounded-rect radius; short surfaces stay capsules since radius = min(side / 2, this)
    static let overshootMargin: CGFloat = 24   // room for spring overshoot inside the panel
    static let dockGap: CGFloat = 12           // gap between the glass and the top of the Dock
    static let grabberSize = CGSize(width: 32, height: 4)
    static let grabberInset: CGFloat = 6       // grabber's distance from the glass's top edge

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
    static let morphBlur: CGFloat = 8       // peak blur during a morph
    static let morphBlurRise: TimeInterval = 0.16  // time for the morph blur to reach its peak
    static let morphBlurFall: TimeInterval = 0.38  // time for it to clear, ending as the springs settle
    static let swapBlur: CGFloat = 16       // blur on content entering / leaving during a swap
    static let swapScale: CGFloat = 0.92    // scale on content entering / leaving during a swap
    static let morphBlurRange: CGFloat = 60 // morphs shorter than this blur proportionally less
    static let bow = Animation.spring(duration: 0.55, bounce: 0.42)      // snap-back after a scroll commits
    static let release = Animation.spring(duration: 0.40, bounce: 0.30)  // snap-back after a scroll that didn't commit
}

enum SurfaceGesture {
    static let commitDistance: CGFloat = 56      // vertical finger travel that commits a collapse / expand
    static let followLimit: CGFloat = 16         // max glass travel while following the scroll (stays inside overshootMargin)
    static let blockedFollowLimit: CGFloat = 6   // follow limit toward a direction that has no action
    static let followStiffness: CGFloat = 0.55   // how quickly the follow approaches its limit
    static let stretch: CGFloat = 0.006          // uniform scale change per point of vertical follow
    static let wheelLineScale: CGFloat = 8       // points per line for non-trackpad scroll wheels
    static let wheelIdle: TimeInterval = 0.15    // a mouse-wheel gesture ends after this much idle time
}
