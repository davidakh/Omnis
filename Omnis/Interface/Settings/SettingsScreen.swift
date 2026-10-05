import ServiceManagement
import SwiftUI

// MARK: - Settings

/// Settings inside the glass: 620×712, a sidebar of panes beside the selected pane. The sidebar
/// can be hidden to give the pane the full width. Back (or pulling down) returns to where
/// settings was opened from.
struct SettingsScreen: View {
    let state: AppState

    @State private var pane: SettingsPane = .general
    @State private var showsSidebar = true

    private static var size: CGSize { CGSize(width: 620, height: 712) }
    private static var sidebarWidth: CGFloat { 180 }

    /// While true, settings is left blank; pulling down still closes it.
    private static var isLocked: Bool { true }

    var body: some View {
        Group {
            if Self.isLocked {
                Color.clear
            } else {
                HStack(spacing: 0) {
                    if showsSidebar {
                        sidebar
                            .frame(width: Self.sidebarWidth)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    detail
                }
            }
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
            ModelSettingsSection(settings: state.settings, resolver: state.resolver, state: state)
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

    var color: AnyShapeStyle {
        switch self {
        case .general, .storage, .backup, .about: AnyShapeStyle(SettingsIcon.gray)
        case .intelligence: SettingsIcon.intelligence
        case .connect: AnyShapeStyle(.indigo)
        case .privacy, .behavior: AnyShapeStyle(.blue)
        case .shortcuts: AnyShapeStyle(.purple)
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

/// Which model answers questions and writes summaries: an intro card, then the agents to choose
/// from (Apple Foundation Models, or Claude or ChatGPT with the user's own API key), then the
/// chosen agent's options.
private struct ModelSettingsSection: View {
    @Bindable var settings: ModelSettings
    let resolver: ModelResolver
    let state: AppState

    /// Bumped when an API key is saved, so the rows' statuses (read from the Keychain) refresh.
    @State private var keysVersion = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IntelligenceCard()
                .padding(.bottom, 10)

            Text("Agents")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(Agent.allCases.enumerated()), id: \.element) { index, agent in
                    if index > 0 {
                        Divider().overlay(.white.opacity(0.05)).padding(.leading, 62)
                    }
                    AgentRow(
                        agent: agent,
                        status: resolver.status(of: agent.provider(current: settings.provider)),
                        isSelected: agent == Agent(settings.provider)
                    ) {
                        settings.provider = agent.provider(current: settings.provider)
                    }
                }
            }
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .id(keysVersion)

            providerOptions
                .padding(.horizontal, 4)
                .padding(.top, 6)
        }
        .animation(SurfaceMotion.content, value: settings.provider)
    }

    @ViewBuilder
    private var providerOptions: some View {
        switch settings.provider {
        case .local:
            VStack(alignment: .leading, spacing: 12) {
                ForEach(LocalModelOption.all) { model in
                    LocalModelRow(
                        model: model,
                        state: state.models.state(of: model),
                        isInstalled: state.models.isInstalled(model),
                        isSelected: settings.localModelID == model.id
                    ) {
                        state.models.download(model)
                    } cancel: {
                        state.models.cancel(model)
                    } use: {
                        state.useDownloadedModel(model)
                    }
                }
                SettingsNote("Answers chats and writes summaries on this Mac with a model downloaded from Hugging Face. Live notes and highlights use Apple's on-device model. Nothing leaves your device.")
            }
            .transition(.blurReplace)
        case .appleOnDevice, .applePrivateCloud:
            VStack(alignment: .leading, spacing: 10) {
                SettingsField("Runs On") {
                    Picker("Runs On", selection: $settings.provider) {
                        Text("This Mac").tag(ModelProvider.appleOnDevice)
                        Text("Private Cloud").tag(ModelProvider.applePrivateCloud)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                if settings.provider == .applePrivateCloud {
                    SettingsNote("Larger context and stronger reasoning on Apple's Private Cloud Compute. Falls back to this Mac when it can't be reached or the daily limit is reached.")
                } else {
                    SettingsNote("Runs entirely on this Mac. Nothing leaves your device.")
                }
            }
            .transition(.blurReplace)
        case .anthropic:
            VStack(alignment: .leading, spacing: 10) {
                SettingsField("Model") {
                    Picker("Model", selection: $settings.anthropicModel) {
                        ForEach(ModelSettings.anthropicModels, id: \.id) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                APIKeyField(settings: settings, provider: .anthropic) { keysVersion += 1 }
                SettingsNote("Questions, transcripts and screen context are sent to Anthropic with your API key.")
            }
            .transition(.blurReplace)
        case .openAI:
            VStack(alignment: .leading, spacing: 10) {
                SettingsField("Model") {
                    TextField("gpt-5", text: $settings.openAIModel)
                        .textFieldStyle(.plain)
                        .settingsInput()
                        .frame(width: 160)
                }
                APIKeyField(settings: settings, provider: .openAI) { keysVersion += 1 }
                SettingsNote("Questions, transcripts and screen context are sent to OpenAI with your API key.")
            }
            .transition(.blurReplace)
        }
    }
}

/// A provider's API key, kept in the Keychain. Shows whether one is saved; typing a new one
/// and pressing Return saves it, and saving an empty field removes it.
private struct APIKeyField: View {
    let settings: ModelSettings
    let provider: ModelProvider
    /// Called after the key is saved or removed.
    let onChange: () -> Void

    @State private var draft = ""
    @State private var hasKey = false

    var body: some View {
        SettingsField("API Key") {
            HStack(spacing: 6) {
                SecureField(hasKey ? "Saved" : "Paste Key", text: $draft)
                    .textFieldStyle(.plain)
                    .settingsInput()
                    .frame(width: 160)
                    .onSubmit(save)
                if hasKey && draft.isEmpty {
                    Button("Remove") {
                        settings.setAPIKey("", for: provider)
                        refresh()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                } else if !draft.isEmpty {
                    Button("Save", action: save)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .onAppear { hasKey = settings.apiKey(for: provider) != nil }
    }

    private func save() {
        guard !draft.isEmpty else { return }
        settings.setAPIKey(draft, for: provider)
        draft = ""
        refresh()
    }

    private func refresh() {
        hasKey = settings.apiKey(for: provider) != nil
        onChange()
    }
}

/// A label with a trailing control, for the provider options.
private struct SettingsField<Control: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let control: () -> Control

    init(_ title: LocalizedStringKey, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.control = control
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            control()
        }
        .frame(minHeight: 28)
    }
}

private extension View {
    /// The look of a text input in settings: white text on a soft capsule.
    func settingsInput() -> some View {
        self
            .font(.system(size: 12))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.white.opacity(0.08), in: Capsule())
    }
}

/// The agents offered in Settings. Apple covers both Foundation Models variants; which one runs
/// is chosen under the list.
private enum Agent: CaseIterable, Hashable {
    case bonsai, apple, claude, chatGPT

    init(_ provider: ModelProvider) {
        switch provider {
        case .local: self = .bonsai
        case .appleOnDevice, .applePrivateCloud: self = .apple
        case .anthropic: self = .claude
        case .openAI: self = .chatGPT
        }
    }

    /// The provider choosing this agent selects; Apple keeps the current variant if it's one.
    func provider(current: ModelProvider) -> ModelProvider {
        switch self {
        case .bonsai: .local
        case .apple: Agent(current) == .apple ? current : .appleOnDevice
        case .claude: .anthropic
        case .chatGPT: .openAI
        }
    }

    var name: LocalizedStringKey {
        switch self {
        case .bonsai: "Bonsai"
        case .apple: "Apple Foundation Model"
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        }
    }

    var maker: String {
        switch self {
        case .bonsai: String(localized: "Prism ML · on this Mac")
        case .apple: String(localized: "Apple")
        case .claude: String(localized: "Anthropic")
        case .chatGPT: String(localized: "OpenAI")
        }
    }

    var symbol: SettingsSymbol {
        switch self {
        case .bonsai: .custom("Bonsai")
        case .apple: .custom("foundation.model")
        case .claude: .custom("claude")
        case .chatGPT: .custom("chatgpt")
        }
    }

    var color: AnyShapeStyle {
        switch self {
        case .bonsai: AnyShapeStyle(Color(red: 0.36, green: 0.55, blue: 0.38))  // bonsai green
        case .apple: SettingsIcon.foundationModel
        case .claude: AnyShapeStyle(Color(red: 0.85, green: 0.47, blue: 0.34))  // Claude's terracotta
        case .chatGPT: AnyShapeStyle(Color(white: 0.12))
        }
    }
}

/// The intro card at the top of Intelligence: its icon, a title and what choosing a model means.
private struct IntelligenceCard: View {
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            SettingsIcon(symbol: .custom("intelligence"), color: SettingsIcon.intelligence)
            VStack(alignment: .leading, spacing: 3) {
                Text("Intelligence")
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text("Supercharge your Omnis experience with built in intelligence and your choice of model. Third-party models will have access to your sessions and recordings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// One agent: its icon, its name and maker (or why it can't be used yet), and a check when
/// it's the one answering.
private struct AgentRow: View {
    let agent: Agent
    let status: String?
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(symbol: agent.symbol, color: agent.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text(status.map { "\(agent.maker) · \($0)" } ?? agent.maker)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .transition(.blurReplace)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(isHovered ? 0.04 : 0))
        .contentShape(Rectangle())
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

/// A white symbol on a rounded, colored tile, like System Settings. The tile is a flat color or
/// a gradient; inner highlights along its top and bottom and shading along its sides give it
/// depth, and the symbol is layered the same way (after DSX's `Icon`, at its medium size).
private struct SettingsIcon: View {
    static let gray = Color(white: 0.55)

    /// Apple Intelligence's colors: yellow at the top left, red to the right, blue along the
    /// bottom and lilac in the corner.
    static let intelligence = AnyShapeStyle(MeshGradient(
        width: 3, height: 3,
        points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.5], [0.55, 0.45], [1, 0.5],
            [0, 1], [0.5, 1], [1, 1]
        ],
        colors: [
            Color(red: 0.91, green: 0.69, blue: 0.24), Color(red: 0.88, green: 0.52, blue: 0.43), Color(red: 0.84, green: 0.4, blue: 0.45),
            Color(red: 0.93, green: 0.77, blue: 0.38), Color(red: 0.85, green: 0.55, blue: 0.55), Color(red: 0.86, green: 0.44, blue: 0.5),
            Color(red: 0.8, green: 0.89, blue: 0.97), Color(red: 0.47, green: 0.64, blue: 0.9), Color(red: 0.7, green: 0.57, blue: 0.9)
        ]
    ))

    /// Foundation Models: green at the top left into blue at the bottom right.
    static let foundationModel = AnyShapeStyle(LinearGradient(
        colors: [Color(red: 0.55, green: 0.84, blue: 0.42), Color(red: 0.33, green: 0.7, blue: 0.82), Color(red: 0.42, green: 0.48, blue: 0.94)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    ))

    let symbol: SettingsSymbol
    let color: AnyShapeStyle

    init(symbol: SettingsSymbol, color: some ShapeStyle) {
        self.symbol = symbol
        self.color = AnyShapeStyle(color)
    }

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
