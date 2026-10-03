import AppKit
import SwiftUI

nonisolated struct GlassStyle: Equatable, Sendable {
    var variant: Int = 2
    var tint: Double = 0.40
    var scrim: Int = 0
    var lensing: Bool = true

    static let surface = GlassStyle()
    static let ultraClear = GlassStyle(variant: 2, tint: 0.25)
}

struct GlassSurface: View, Animatable {
    var radius: CGFloat
    var style: GlassStyle = .surface

    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    var body: some View {
        GlassBackdrop(radius: radius, style: style).allowsHitTesting(false)
    }
}

private struct GlassBackdrop: NSViewRepresentable {
    var radius: CGFloat
    var style: GlassStyle

    func makeNSView(context: Context) -> GlassBackdropView {
        let view = GlassBackdropView(frame: .zero)
        view.configure(radius: radius, style: style)
        return view
    }

    func updateNSView(_ view: GlassBackdropView, context: Context) {
        view.configure(radius: radius, style: style)
    }
}

final class GlassBackdropView: NSGlassEffectView {
    private var glassStyle: GlassStyle?
    private var observing = false

    func configure(radius: CGFloat, style: GlassStyle) {
        if cornerRadius != radius { cornerRadius = radius }
        guard glassStyle != style else { return }
        glassStyle = style
        reassert()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startObserving()
        reassert()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reassert()
    }

    private func startObserving() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification
        ]
        for name in names {
            center.addObserver(self, selector: #selector(activeStateChanged), name: name, object: nil)
        }
    }

    @objc private func activeStateChanged() {
        reassert()
        DispatchQueue.main.async { [weak self] in self?.reassert() }
    }

    private func reassert() {
        guard let glassStyle else { return }
        style = glassStyle.variant == 2 ? .clear : .regular
        tintColor = glassStyle.tint > 0 ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: glassStyle.tint) : nil
        setPrivateValue(min(max(glassStyle.variant, 0), 8), forKey: "_variant")
        setPrivateValue(min(max(glassStyle.scrim, 0), 2), forKey: "_scrimState")
        setPrivateValue(glassStyle.lensing, forKey: "_contentLensing")
        setPrivateValue(0, forKey: "_subduedState")
        setPrivateValue(false, forKey: "_tintOpacityReduced")
    }
}

extension NSView {
    func setPrivateValue(_ value: Any, forKey key: String) {
        guard responds(to: NSSelectorFromString("set\(key):")) else { return }
        setValue(value, forKey: key)
    }
}

enum SurfaceShade {
    static let gradient = LinearGradient(
        stops: [.init(color: .black, location: 0.32), .init(color: .black.opacity(0.32), location: 1)],
        startPoint: .top, endPoint: .bottom
    )
}
