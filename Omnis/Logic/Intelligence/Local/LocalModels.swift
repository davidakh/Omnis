import Foundation

/// A model Omnis can download from Hugging Face and run on this Mac with MLX.
struct LocalModelOption: Identifiable, Hashable {
    /// The Hugging Face repo, e.g. "prism-ml/Bonsai-8B-mlx-1bit".
    let id: String
    let name: String
    /// How it's described in the list: "Huge", "Larger", "Tiny".
    let size: String
    /// Memory the Mac needs to run it comfortably, in GB.
    let requiredMemory: Int
    /// Can look at images (the screen) itself.
    let supportsVision: Bool
    /// Tokens of context it can read; prompts are capped below this to bound memory.
    let contextLength: Int

    static let all: [LocalModelOption] = [
        LocalModelOption(
            id: "prism-ml/Bonsai-27B-mlx-1bit", name: "Bonsai 27B", size: String(localized: "Huge"),
            requiredMemory: 16, supportsVision: true, contextLength: 262_144
        ),
        LocalModelOption(
            id: "prism-ml/Bonsai-8B-mlx-1bit", name: "Bonsai 8B", size: String(localized: "Larger"),
            requiredMemory: 8, supportsVision: false, contextLength: 65_536
        ),
        LocalModelOption(
            id: "prism-ml/Bonsai-4B-mlx-1bit", name: "Bonsai 4B", size: String(localized: "Tiny"),
            requiredMemory: 4, supportsVision: false, contextLength: 32_768
        )
    ]

    static func option(withID id: String) -> LocalModelOption? { all.first { $0.id == id } }

    /// Whether this Mac has the memory for it.
    var fitsThisMac: Bool {
        ProcessInfo.processInfo.physicalMemory >= UInt64(requiredMemory) * 1_073_741_824
    }

    /// Where its files live: one folder per model, named after the repo so each has its own
    /// identity in MLX's model cache.
    var directory: URL {
        LocalModelStore.root.appending(path: id.replacingOccurrences(of: "/", with: "--"), directoryHint: .isDirectory)
    }
}

/// Downloads models from Hugging Face and keeps track of which are installed.
@MainActor
@Observable
final class LocalModelStore {
    enum DownloadState: Equatable {
        case idle
        /// Bytes so far of the total.
        case downloading(received: Int64, total: Int64)
        case failed(String)
    }

    /// Installed models, by repo id.
    private(set) var installed: Set<String> = []
    private(set) var downloads: [String: DownloadState] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    static let root: URL = URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)

    /// Written once every file is in place, so a half-finished download never counts as installed.
    private static let completeMarker = ".omnis-complete"

    init() {
        installed = Set(LocalModelOption.all.filter { Self.isComplete($0) }.map(\.id))
    }

    func state(of model: LocalModelOption) -> DownloadState { downloads[model.id] ?? .idle }

    func isInstalled(_ model: LocalModelOption) -> Bool { installed.contains(model.id) }

    /// Starts (or restarts) downloading a model. Files already fully downloaded are kept.
    func download(_ model: LocalModelOption) {
        guard tasks[model.id] == nil, !isInstalled(model) else { return }
        downloads[model.id] = .downloading(received: 0, total: 0)
        tasks[model.id] = Task { [weak self] in
            do {
                try await Self.fetch(model) { received, total in
                    Task { @MainActor in self?.downloads[model.id] = .downloading(received: received, total: total) }
                }
                self?.installed.insert(model.id)
                self?.downloads[model.id] = nil
            } catch is CancellationError {
                self?.downloads[model.id] = nil
            } catch {
                self?.downloads[model.id] = .failed(error.localizedDescription)
            }
            self?.tasks[model.id] = nil
        }
    }

    func cancel(_ model: LocalModelOption) {
        tasks[model.id]?.cancel()
    }

    func delete(_ model: LocalModelOption) {
        cancel(model)
        try? FileManager.default.removeItem(at: model.directory)
        installed.remove(model.id)
    }

    // MARK: - Downloading

    private struct RepoFile: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    /// What MLX needs: weights, configs, tokenizer and chat template. READMEs, images and
    /// evaluation files are skipped.
    private static func isNeeded(_ path: String) -> Bool {
        guard !path.contains("/") else { return false }
        return [".safetensors", ".json", ".jinja", ".txt"].contains { path.hasSuffix($0) }
    }

    nonisolated private static func fetch(
        _ model: LocalModelOption,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let listURL = URL(string: "https://huggingface.co/api/models/\(model.id)/tree/main?recursive=1")!
        let (data, response) = try await URLSession.shared.data(from: listURL)
        try check(response)
        let files = try JSONDecoder().decode([RepoFile].self, from: data)
            .filter { $0.type == "file" && isNeeded($0.path) }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: model.directory, withIntermediateDirectories: true)

        let total = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var finished: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = model.directory.appending(path: file.path)
            // Already here from an earlier attempt.
            if let size = file.size,
               let existing = try? fileManager.attributesOfItem(atPath: destination.path(percentEncoded: false))[.size] as? Int64,
               existing == size {
                finished += size
                progress(finished, total)
                continue
            }
            let url = URL(string: "https://huggingface.co/\(model.id)/resolve/main/\(file.path)")!
            let base = finished
            let delegate = ProgressDelegate { written in progress(base + written, total) }
            let (temporary, fileResponse) = try await URLSession.shared.download(from: url, delegate: delegate)
            try check(fileResponse)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)
            finished += file.size ?? 0
            progress(finished, total)
        }
        fileManager.createFile(atPath: model.directory.appending(path: completeMarker).path(percentEncoded: false), contents: nil)
    }

    nonisolated private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        throw URLError(.badServerResponse, userInfo: [
            NSLocalizedDescriptionKey: String(localized: "Hugging Face returned an error (\(http.statusCode)).")
        ])
    }

    nonisolated private static func isComplete(_ model: LocalModelOption) -> Bool {
        FileManager.default.fileExists(atPath: model.directory.appending(path: completeMarker).path(percentEncoded: false))
    }
}

/// Reports bytes written for one file as it downloads.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let onWrite: @Sendable (Int64) -> Void

    init(onWrite: @escaping @Sendable (Int64) -> Void) {
        self.onWrite = onWrite
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onWrite(totalBytesWritten)
    }

    // The async `download(from:delegate:)` call hands back the file itself.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
