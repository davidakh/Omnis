import AppKit

/// Borderless floating panel that always reports an active appearance, so the glass never dims.
final class SurfacePanel: NSPanel {
    override var canBecomeKey: Bool { true }   // text fields will need typing later
    override var canBecomeMain: Bool { true }
    @objc(_hasActiveAppearance) var forcedActiveAppearance: Bool { true }
    @objc(_hasActiveAppearanceIgnoringKeyFocus) var forcedActiveAppearanceIgnoringKeyFocus: Bool { true }
    @objc(_hasActiveControls) var forcedActiveControls: Bool { true }
}
