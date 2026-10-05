import AppKit
import FoundationModels
import ScreenCaptureKit
import Vision

/// What was on screen when the question was asked: the frontmost window under the surface.
struct ScreenSnapshot {
    let appName: String
    let windowTitle: String?
    /// Sent to models that accept images.
    let image: CGImage
    /// Recognized text in reading order, one visual row per line, with wide gaps (columns,
    /// table cells) kept as " | ", for every model.
    let text: String
    /// What the image shows, by Vision's classifier ("document", "chart", "screenshot"…).
    let labels: [String]
    /// The contents of QR codes and barcodes on screen (often links).
    let codes: [String]
    /// A description of what's visible (layout, images, charts, UI), written by Apple's
    /// on-device model for text-only models that can't see the image themselves.
    var visualDescription: String?
}

enum ScreenCaptureError: LocalizedError {
    case permissionNeeded
    /// The Screen source is switched off in Omnis.
    case turnedOff
    case noWindow
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .turnedOff:
            String(localized: "Screen not included: the Screen source is turned off.")
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

/// The Screen Recording permission, shared by screen context and call-audio recording.
enum ScreenRecordingPermission {
    private static var hasRequestedThisLaunch = false

    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Returns whether access is granted. If it isn't, asks the system once per launch rather
    /// than on every capture, so the user isn't prompted again and again.
    @discardableResult
    static func ensure() -> Bool {
        if isGranted { return true }
        if !hasRequestedThisLaunch {
            hasRequestedThisLaunch = true
            CGRequestScreenCaptureAccess()
        }
        return false
    }
}

/// Captures the frontmost app's frontmost window (never Omnis's own panel) and reads its text.
enum ScreenContextProvider {
    /// Matches the image size the providers process; anything larger is downscaled anyway.
    private static let maxPixelDimension: CGFloat = 1568

    static func capture() async throws -> ScreenSnapshot {
        guard ScreenRecordingPermission.ensure() else {
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
        // Read the text, classify the image and decode any codes at once.
        async let text = recognizeText(in: image)
        async let labels = classify(image)
        async let codes = readCodes(in: image)

        return ScreenSnapshot(
            appName: window.owningApplication?.applicationName ?? String(localized: "Unknown app"),
            windowTitle: window.title.flatMap { $0.isEmpty ? nil : $0 },
            image: image,
            text: try await text,
            labels: await labels,
            codes: await codes
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

    /// Has Apple's on-device model describe what's visible, for models that only read text.
    /// Nil when that model can't take images or isn't available.
    static func describe(_ image: CGImage) async -> String? {
        let model = SystemLanguageModel.default
        guard model.isAvailable, model.capabilities.contains(.vision) else { return nil }
        let session = LanguageModelSession(model: model, instructions: """
            You describe a screenshot of one app window for someone who can't see it. Cover what \
            kind of app or page it is, how it's laid out, and what matters: headings, selected or \
            highlighted items, images, charts and what they show, buttons, errors and dialogs. \
            Describe only what's visible; never guess. Plain prose, at most 150 words.
            """)
        let response = try? await session.respond(options: GenerationOptions(temperature: 0.1)) {
            "Describe this window."
            Attachment(image)
        }
        return response?.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Text grouped into visual rows, top to bottom and left to right, so tables, sidebars and
    /// columns keep their shape instead of arriving as one jumbled list.
    private static func recognizeText(in image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let observations = try await request.perform(on: image)
        let pieces: [(text: String, box: CGRect)] = observations.compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (text, observation.boundingBox.cgRect)
        }

        // Vision's boxes are normalized with the origin at the bottom left.
        var rows: [[(text: String, box: CGRect)]] = []
        for piece in pieces.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = rows.last?.last, abs(last.box.midY - piece.box.midY) < min(last.box.height, piece.box.height) * 0.6 {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        return rows.map { row in
            let sorted = row.sorted { $0.box.minX < $1.box.minX }
            var line = ""
            for (index, piece) in sorted.enumerated() {
                if index > 0 {
                    // A wide gap is a new column or table cell.
                    let gap = piece.box.minX - sorted[index - 1].box.maxX
                    line += gap > 0.04 ? " | " : " "
                }
                line += piece.text
            }
            return line
        }
        .joined(separator: "\n")
    }

    /// The likeliest few things the image shows; empty if the classifier isn't confident.
    private static func classify(_ image: CGImage) async -> [String] {
        guard let observations = try? await ClassifyImageRequest().perform(on: image) else { return [] }
        return observations
            .filter { $0.hasMinimumPrecision(0.7, forRecall: 0.5) }
            .sorted { $0.confidence > $1.confidence }
            .prefix(6)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    private static func readCodes(in image: CGImage) async -> [String] {
        guard let observations = try? await DetectBarcodesRequest().perform(on: image) else { return [] }
        return Array(Set(observations.compactMap(\.payloadString)))
    }
}
