import ServiceManagement
import SwiftUI

// MARK: - Settings

/// Settings inside the glass: 512×612, a sidebar of panes beside the selected pane. The sidebar
/// can be hidden to give the pane the full width. Back (or pulling down) returns to where
/// settings was opened from.
struct SettingsScreen: View {
    let state: AppState

    @State private var pane: SettingsPane = .general
    @State private var showsSidebar = true

    private static var size: CGSize { CGSize(width: 512, height: 612) }
    private static var sidebarWidth: CGFloat { 180 }

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                sidebar
                    .frame(width: Self.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            detail
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(SurfaceMotion.content, value: showsSidebar)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                SurfaceButton("chevron.left") { state.closeSettings() }
                SettingsTitle("Settings")
            }
            .padding([.top, .horizontal], 20)

            VStack(spacing: 18) {
                ForEach(SettingsPane.groups, id: \.self) { group in
                    VStack(spacing: 2) {
                        ForEach(group) { item in
                            SidebarRow(pane: item, isSelected: pane == item) { pane = item }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.white.opacity(0.05))
    }

    // MARK: Detail

    private var detail: some View {
        ZStack(alignment: .top) {
            FadingScroll(height: Self.size.height, topClear: 72, bottomClear: 24) {
                paneContent
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(pane)  // each pane starts at the top
            .transition(.blurReplace)

            HStack(spacing: 12) {
                // With the sidebar hidden, its back button moves here.
                if !showsSidebar {
                    SurfaceButton("chevron.left") { state.closeSettings() }
                        .transition(.blurReplace)
                }
                SurfaceButton("sidebar.left") { showsSidebar.toggle() }
                SettingsTitle(pane.title)
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(SurfaceMotion.content, value: pane)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .general:
            LaunchAtLoginRow()
        case .intelligence:
            ModelSettingsSection(settings: state.settings, resolver: state.resolver)
        case .connect, .privacy, .shortcuts, .behavior, .storage, .backup, .about:
            SettingsNote("Nothing to set here yet.")
        }
    }
}

/// The panes in the settings sidebar, in order.
enum SettingsPane: Hashable, Identifiable {
    case general, intelligence
    case connect, privacy, shortcuts, behavior
    case storage, backup, about

    /// The sidebar's groups, separated by a gap.
    static let groups: [[SettingsPane]] = [
        [.general, .intelligence],
        [.connect, .privacy, .shortcuts, .behavior],
        [.storage, .backup, .about]
    ]

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .intelligence: "Intelligence"
        case .connect: "Connect"
        case .privacy: "Privacy"
        case .shortcuts: "Shortcuts"
        case .behavior: "Behavior"
        case .storage: "Storage"
        case .backup: "Backup"
        case .about: "About"
        }
    }

    var symbol: SettingsSymbol {
        switch self {
        case .general: .system("gearshape.fill")
        case .intelligence: .custom("intelligence")
        case .connect: .custom("model.context.protocal")
        case .privacy: .system("hand.raised.fill")
        case .shortcuts: .system("keyboard.fill")
        case .behavior: .system("rectangle.grid.1x2.fill")
        case .storage: .system("internaldrive.fill")
        case .backup: .system("clock.arrow.circlepath")
        case .about: .system("info.circle")
        }
    }

    var color: Color {
        switch self {
        case .general, .storage, .backup, .about: SettingsIcon.gray
        case .intelligence: .red
        case .connect: .indigo
        case .privacy, .behavior: .blue
        case .shortcuts: .purple
        }
    }
}

private struct SidebarRow: View {
    let pane: SettingsPane
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            SettingsIcon(symbol: pane.symbol, color: pane.color)
            Text(pane.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
        .background(.white.opacity(isSelected ? 0.1 : (isHovered ? 0.05 : 0)), in: Capsule())
        .contentShape(Capsule())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: select)
        .animation(.smooth(duration: 0.15), value: isHovered)
        .animation(.smooth(duration: 0.2), value: isSelected)
    }
}

/// Opens Omnis when you log in, through the system's login items.
private struct LaunchAtLoginRow: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        SettingsRow(symbol: .system("person.crop.circle"), color: .blue, title: "Launch at Login") {
            Toggle("Launch at Login", isOn: Binding(get: { isEnabled }, set: setEnabled))
                .labelsHidden()
                .tint(.white.opacity(0.25))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Leave the switch showing what the system actually has.
        }
        isEnabled = SMAppService.mainApp.status == .enabled
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

private struct SettingsTitle: View {
    let title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .toolbarTitleShadow()
    }
}

/// An SF Symbol, or a custom symbol from the asset catalog (`Assets.xcassets/Symbol`).
enum SettingsSymbol: Hashable {
    case system(String)
    case custom(String)

    var image: Image {
        switch self {
        case .system(let name): Image(systemName: name)
        case .custom(let name): Image(name)
        }
    }

    /// The custom symbols are drawn smaller within their frame than SF Symbols, so they're
    /// set larger to look the same size on the tile.
    var pointSize: CGFloat {
        switch self {
        case .system: 12
        case .custom: 15
        }
    }
}

/// A white symbol on a rounded, colored tile, like System Settings. The tile is one flat color;
/// inner highlights along its top and bottom and shading along its sides give it depth, and
/// the symbol is layered the same way (after DSX's `Icon`, at its medium size).
private struct SettingsIcon: View {
    static let gray = Color(white: 0.55)

    let symbol: SettingsSymbol
    let color: Color

    private static var frame: CGFloat { 22 }
    private static var corner: CGFloat { 6.5 }

    /// Effects shrink with the tile, gentler for the symbol than for the tile (DSX's curves).
    private static func scaled(curve: Double) -> CGFloat { CGFloat(pow(Double(frame / 256), curve)) }
    private static var tileOffset: CGFloat { 2.25 * scaled(curve: 0.45) }
    private static var tileBlur: CGFloat { 1.25 * scaled(curve: 0.45) }
    private static var symbolOffset: CGFloat { 1.25 * scaled(curve: 0.3) }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
    }

    var body: some View {
        ZStack {
            glyph(.white.opacity(0.1), blend: .plusLighter)
            glyph(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.25)], startPoint: .top, endPoint: .bottom))
            glyph(
                Color.black
                    .shadow(.inner(color: .white.opacity(0.2), radius: 0, x: 0, y: Self.symbolOffset))
                    .shadow(.inner(color: .white.opacity(0.2), radius: 0, x: 0, y: -Self.symbolOffset)),
                blend: .plusLighter
            )
            glyph(
                Color.white
                    .shadow(.drop(color: .black.opacity(0.25), radius: 0, x: Self.symbolOffset, y: 0))
                    .shadow(.drop(color: .black.opacity(0.25), radius: 0, x: -Self.symbolOffset, y: 0)),
                blend: .plusDarker
            )
        }
        .frame(width: Self.frame, height: Self.frame)
        .background { tile }
        // Resolve every blend inside the icon. Otherwise, while the surface's swap transition
        // (blur, fade) flattens the content, the white effect layers blend against nothing
        // and the tile shows white.
        .compositingGroup()
    }

    private var tile: some View {
        ZStack {
            shape.fill(color)
            // Highlights along the top and bottom edges.
            shape
                .fill(
                    Color.black
                        .shadow(.inner(color: .white.opacity(0.2), radius: Self.tileBlur, x: 0, y: Self.tileOffset))
                        .shadow(.inner(color: .white.opacity(0.2), radius: Self.tileBlur, x: 0, y: -Self.tileOffset))
                )
                .blendMode(.plusLighter)
            // Shading along the sides.
            shape
                .fill(
                    Color.white
                        .shadow(.inner(color: .black.opacity(0.15), radius: Self.tileBlur, x: Self.tileOffset, y: 0))
                        .shadow(.inner(color: .black.opacity(0.15), radius: Self.tileBlur, x: -Self.tileOffset, y: 0))
                )
                .blendMode(.darken)
        }
    }

    @ViewBuilder
    private func glyph(_ style: some ShapeStyle, blend: BlendMode? = nil) -> some View {
        let layer = symbol.image
            .font(.system(size: symbol.pointSize, weight: .semibold))
            .foregroundStyle(style)
        if let blend {
            // Isolate each effect layer before blending so its own shadows don't wash the symbol out.
            layer.compositingGroup().blendMode(blend)
        } else {
            layer
        }
    }
}

/// An icon, a title, and a trailing control.
private struct SettingsRow<Control: View>: View {
    let symbol: SettingsSymbol
    let color: Color
    let title: LocalizedStringKey
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: symbol, color: color)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            control()
        }
        .frame(minHeight: 36)
    }
}

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
