import AVFoundation
import SwiftUI

/// Shown once, after a model is downloaded: asks for Screen Recording (screen context and call
/// audio), then the microphone, one card at a time. Steps already granted are skipped, and
/// Omnis opens after the last one.
struct PermissionsScreen: View {
    let state: AppState

    @State private var step: PermissionStep? = PermissionStep.firstNeeded(after: nil)

    var body: some View {
        Group {
            if let step {
                PermissionCard(step: step) { allow(step) }
                    .id(step)
                    .transition(.blurReplace)
            }
        }
        .frame(width: 340)
        .onAppear { if step == nil { state.finishPermissions() } }
    }

    private func allow(_ current: PermissionStep) {
        Task {
            await current.request()
            let next = PermissionStep.firstNeeded(after: current)
            if let next {
                withAnimation(SurfaceMotion.content) { step = next }
            } else {
                state.finishPermissions()
            }
        }
    }
}

/// One permission Omnis asks for during setup, in order.
enum PermissionStep: CaseIterable, Hashable {
    case screen, microphone

    var symbol: String {
        switch self {
        case .screen: "inset.filled.rectangle.and.person.filled"
        case .microphone: "microphone.fill"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .screen: "Allow Screen Context"
        case .microphone: "Allow Microphone"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .screen: "Allow Omnis to see your screen and hear your meetings and audio."
        case .microphone: "Allow Omnis to hear you in sessions. You can pause the use of your microphone."
        }
    }

    var isGranted: Bool {
        switch self {
        case .screen: ScreenRecordingPermission.isGranted
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    /// Shows the system prompt (or, for Screen Recording once declined, nothing: the system
    /// only asks once, and the user grants it in Privacy & Security).
    func request() async {
        switch self {
        case .screen: ScreenRecordingPermission.ensure()
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
    }

    /// The next step that isn't granted yet, after `step` (or from the start).
    static func firstNeeded(after step: PermissionStep?) -> PermissionStep? {
        let start = step.flatMap { allCases.firstIndex(of: $0).map { $0 + 1 } } ?? 0
        return allCases[start...].first { !$0.isGranted }
    }
}

/// A large symbol, a title and what the permission is for, and a white Allow button.
private struct PermissionCard: View {
    let step: PermissionStep
    let allow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: step.symbol)
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.25))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .padding(.bottom, 28)

            Text(step.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
            Text(step.message)
                .font(.body)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            Button(action: allow) {
                Text("Allow")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.white).interactive(), in: Capsule())
            .padding(.top, 18)
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 24)
    }
}
