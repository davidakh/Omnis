import SwiftUI

/// Shown until a model is downloaded: Omnis answers chats and writes summaries with a model
/// that runs on this Mac, so one has to be here first. Choosing a model downloads it from
/// Hugging Face; once it's in place Omnis opens.
struct ModelSetupScreen: View {
    let state: AppState

    private var store: LocalModelStore { state.models }

    var body: some View {
        VStack(spacing: 22) {
            Text("Download a Model")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .toolbarTitleShadow()

            VStack(spacing: 14) {
                ForEach(LocalModelOption.all) { model in
                    ModelRow(model: model, state: store.state(of: model), isInstalled: store.isInstalled(model)) {
                        store.download(model)
                    } cancel: {
                        store.cancel(model)
                    } use: {
                        state.useDownloadedModel(model)
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
        .frame(width: 400)
        // Opens Omnis as soon as the first download lands.
        .onChange(of: store.installed) { _, installed in
            guard let first = LocalModelOption.all.first(where: { installed.contains($0.id) }) else { return }
            state.useDownloadedModel(first)
        }
    }
}

private struct ModelRow: View {
    let model: LocalModelOption
    let state: LocalModelStore.DownloadState
    let isInstalled: Bool
    let download: () -> Void
    let cancel: () -> Void
    let use: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            BonsaiTile(size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.2), value: subtitle)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            control
        }
        .opacity(model.fitsThisMac ? 1 : 0.45)
    }

    private var subtitle: String {
        switch state {
        case .downloading(let received, let total) where total > 0:
            let done = received.formatted(.byteCount(style: .file))
            let all = total.formatted(.byteCount(style: .file))
            return String(localized: "Downloading, \(done) of \(all)")
        case .downloading:
            return String(localized: "Starting download…")
        case .failed(let message):
            return message
        case .idle:
            if isInstalled { return String(localized: "Downloaded") }
            if !model.fitsThisMac { return String(localized: "Needs \(model.requiredMemory) GB of memory") }
            return String(localized: "\(model.size), \(model.requiredMemory)GBs Required")
        }
    }

    @ViewBuilder
    private var control: some View {
        switch state {
        case .downloading(let received, let total):
            // The stop button, ringed by how far along the download is.
            SurfaceButton("stop.fill", action: cancel)
                .overlay {
                    Circle()
                        .trim(from: 0, to: total > 0 ? Double(received) / Double(total) : 0)
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(-3)
                        .animation(.linear(duration: 0.2), value: received)
                        .allowsHitTesting(false)
                }
                .transition(.blurReplace)
        case .failed:
            SurfaceButton("arrow.clockwise", action: download)
                .transition(.blurReplace)
        case .idle where isInstalled:
            SurfaceButton("checkmark", style: .prominent, action: use)
                .transition(.blurReplace)
        case .idle:
            SurfaceButton("arrow.down", action: download)
                .disabled(!model.fitsThisMac)
                .transition(.blurReplace)
        }
    }
}

/// The Bonsai mark on a light rounded tile, like an app icon.
struct BonsaiTile: View {
    let size: CGFloat

    var body: some View {
        Image("Bonsai")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.black)
            .padding(size * 0.2)
            .frame(width: size, height: size)
            .background(Color(white: 0.93), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
    }
}
