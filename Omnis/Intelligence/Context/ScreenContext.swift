import AppKit
import ScreenCaptureKit
import Vision

/// What was on screen when the question was asked: the frontmost window under the surface.
struct ScreenSnapshot {
    let appName: String
    let windowTitle: String?
    /// Sent to models that accept images.
    let image: CGImage
    /// Recognized text, for every model (and the only screen context for text-only ones).
    let text: String
}

enum ScreenCaptureError: LocalizedError {
    case permissionNeeded
    case noWindow
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionNeeded:
            String(localized: "Enable screen context for Omnis")
        case .noWindow:
            String(localized: "Screen not included: there's no window to look at.")
        case .captureFailed(let reason):
            String(localized: "Screen not included: \(reason)")
        }
    }

    /// The Privacy & Security pane where Screen Recording is granted.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
}

/// Captures the frontmost app's frontmost window (never Omnis's own panel) and reads its text.
enum ScreenContextProvider {
    /// Matches the image size the providers process; anything larger is downscaled anyway.
    private static let maxPixelDimension: CGFloat = 1568

    static func capture() async throws -> ScreenSnapshot {
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt the first time; afterwards the user grants it in Settings.
            CGRequestScreenCaptureAccess()
            throw ScreenCaptureError.permissionNeeded
        }

        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let windowID = frontmostWindowID(),
              let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenCaptureError.noWindow
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let pointSize = window.frame.size
        let pixelScale = CGFloat(filter.pointPixelScale)
        let scale = min(pixelScale, maxPixelDimension / max(pointSize.width, pointSize.height, 1))
        configuration.width = max(1, Int(pointSize.width * scale))
        configuration.height = max(1, Int(pointSize.height * scale))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let text = try await recognizeText(in: image)

        return ScreenSnapshot(
            appName: window.owningApplication?.applicationName ?? String(localized: "Unknown app"),
            windowTitle: window.title.flatMap { $0.isEmpty ? nil : $0 },
            image: image,
            text: text
        )
    }

    /// The topmost normal window that isn't ours. The surface is a non-activating panel, so
    /// the app the user was working in stays frontmost while they type a question.
    private static func frontmostWindowID() -> CGWindowID? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        // Front to back; layer 0 is ordinary app windows.
        let candidates = windows.filter { info in
            (info[kCGWindowLayer as String] as? Int) == 0
                && (info[kCGWindowOwnerPID as String] as? pid_t) != ownPID
        }
        let preferred = candidates.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == frontmostPID } ?? candidates.first
        return (preferred?[kCGWindowNumber as String] as? Int).map { CGWindowID($0) }
    }

    private static func recognizeText(in image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
