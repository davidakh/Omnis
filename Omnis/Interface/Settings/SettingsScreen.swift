import SwiftUI

// MARK: - Settings

/// Settings inside the glass: 512×612. For now, which model answers questions and writes
/// summaries. Back (or pulling down) returns to where it was opened from.
struct SettingsScreen: View {
    let state: AppState

    var body: some View {
        ZStack {
            FadingScroll(height: 612, topClear: 64, bottomClear: 24) {
                ModelSettingsSection(settings: state.settings, resolver: state.resolver)
            }
            VStack(spacing: 0) {
                ZStack {
                    Text("Settings")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    HStack {
                        SurfaceButton("chevron.left") { state.closeSettings() }
                        Spacer()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(width: 512, height: 612)
    }
}

/// Which Apple Foundation Models variant answers questions and writes summaries.
private struct ModelSettingsSection: View {
    @Bindable var settings: ModelSettings
    let resolver: ModelResolver

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsHeader("Model")
            VStack(spacing: 2) {
                ForEach(ModelProvider.selectable) { provider in
                    ProviderRow(
                        provider: provider,
                        status: resolver.status(of: provider),
                        isSelected: settings.provider == provider
                    ) {
                        settings.provider = provider
                    }
                }
            }
            .padding(.horizontal, -10)  // rows inset their text by 10 pt for the hover tint

            Group {
                if settings.provider == .applePrivateCloud {
                    SettingsNote("Larger context and stronger reasoning on Apple's Private Cloud Compute. Falls back to the on-device model when it can't be reached or the daily limit is reached.")
                } else {
                    SettingsNote("Runs entirely on this Mac. Nothing leaves your device.")
                }
            }
            .padding(.top, 8)
        }
    }
}

private struct ProviderRow: View {
    let provider: ModelProvider
    let status: String?
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? .white : .white.opacity(0.4))
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                if let status {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            .white.opacity(isSelected ? 0.12 : (isHovered ? 0.06 : 0)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture(perform: select)
        .animation(.smooth(duration: 0.15), value: isHovered)
        .animation(.smooth(duration: 0.2), value: isSelected)
    }
}

// MARK: - Building blocks

private struct SettingsHeader: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
            .textCase(.uppercase)
    }
}

private struct SettingsNote: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
    }
}
