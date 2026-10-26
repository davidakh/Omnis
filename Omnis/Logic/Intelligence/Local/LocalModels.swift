import Foundation
import os

/// A model Omnis can download from Hugging Face and run on this Mac with MLX.
nonisolated struct LocalModelOption: Identifiable, Hashable {
    /// The Hugging Face repo, e.g. "prism-ml/Ternary-Bonsai-2-9B-mlx-2bit".
    let id: String
    let name: String
    /// How it's described in the list: "Huge", "Large", "Tiny".
    let size: String
    /// Memory the Mac needs to run it comfortably, in GB.
    let requiredMemory: Int
    /// Can look at images (the screen) itself.
    let supportsVision: Bool
    /// Tokens of context it can read; prompts are capped below this to bound memory.
    let contextLength: Int
    /// Prompt tokens it reads per second, as a starting point until it has been timed on this
    /// Mac (measured on an M2 Max).
    let estimatedPromptSpeed: Double

    /// Bonsai 2: ternary (2-bit) Qwen 3.5 models from PrismML, each with a vision tower.
    static let all: [LocalModelOption] = [
        LocalModelOption(
            id: "prism-ml/Ternary-Bonsai-2-27B-mlx-2bit", name: "Bonsai 2 27B", size: String(localized: "Huge"),
            requiredMemory: 16, supportsVision: true, contextLength: 262_144,
            estimatedPromptSpeed: 110
        ),
        LocalModelOption(
            id: "prism-ml/Ternary-Bonsai-2-9B-mlx-2bit", name: "Bonsai 2 9B", size: String(localized: "Large"),
            requiredMemory: 8, supportsVision: true, contextLength: 262_144,
            estimatedPromptSpeed: 500
        ),
        LocalModelOption(
            id: "prism-ml/Ternary-Bonsai-2-4B-mlx-2bit", name: "Bonsai 2 4B", size: String(localized: "Small"),
            requiredMemory: 4, supportsVision: true, contextLength: 262_144,
            estimatedPromptSpeed: 900
        ),
        LocalModelOption(
            id: "prism-ml/Ternary-Bonsai-2-2B-mlx-2bit", name: "Bonsai 2 2B", size: String(localized: "Tiny"),
            requiredMemory: 4, supportsVision: true, contextLength: 262_144,
            estimatedPromptSpeed: 1_500
        )
    ]

    static func option(withID id: String) -> LocalModelOption? { all.first { $0.id == id } }

    /// Whether this Mac has the memory for it.
    var fitsThisMac: Bool {
        ProcessInfo.processInfo.physicalMemory >= UInt64(requiredMemory) * 1_073_741_824
    }

    /// Tokens of context a chat answer reads: about `promptWait` seconds of reading at the speed
    /// it reads prompts on this Mac. A downloaded model reads every prompt token before its
    /// first word, so this is what keeps answers prompt.
    var chatBudget: Int {
        let speed = LocalModelSpeed.promptTokensPerSecond(for: self) ?? estimatedPromptSpeed
        return min(max(Int(speed * Self.promptWait), Self.minimumChatBudget), Self.maximumChatBudget)
    }

    /// Web and screen context arrive as the most relevant passages, so a few seconds' worth
    /// carries what an answer needs.
    private static let promptWait = 3.5
    /// Enough for the question, the instructions and a little screen or web context.
    private static let minimumChatBudget = 1_000
    private static let maximumChatBudget = 8_000

    /// Where its files live: one folder per model, named after the repo so each has its own
    /// identity in MLX's model cache.
    var directory: URL {
        LocalModelStore.root.appending(path: id.replacingOccurrences(of: "/", with: "--"), directoryHint: .isDirectory)
    }
}

/// How fast each downloaded model reads prompts on this Mac, timed on real answers and
/// remembered across launches.
nonisolated enum LocalModelSpeed {
    private static let key = "model.local.promptSpeed"

    static func promptTokensPerSecond(for model: LocalModelOption) -> Double? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[model.id]
    }

    /// Records one answer's prompt reading: `tokens` read in `seconds` before its first word.
    /// Short prompts are mostly fixed overhead, so only longer ones count; each new timing is
    /// blended with the last so one slow answer (another app busy on the GPU) doesn't swing it.
    static func record(tokens: Int, seconds: Double, for model: LocalModelOption) {
        guard tokens >= 400, seconds > 0.05 else { return }
        var speeds = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        let measured = Double(tokens) / seconds
        let previous = speeds[model.id] ?? model.estimatedPromptSpeed
        speeds[model.id] = 0.6 * previous + 0.4 * measured
        UserDefaults.standard.set(speeds, forKey: key)
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

    nonisolated static let root: URL = URL.applicationSupportDirectory.appending(path: "Models", directoryHint: .isDirectory)

    /// Written once every file is in place, so a half-finished download never counts as installed.
    nonisolated private static let completeMarker = ".omnis-complete"

    init() {
        installed = Set(LocalModelOption.all.filter { Self.isComplete($0) }.map(\.id))
        Task.detached(priority: .utility) { Self.removeRetiredModels() }
    }

    /// Deletes downloaded models Omnis no longer offers (the original Bonsai), so their
    /// gigabytes don't linger after an update.
    nonisolated private static func removeRetiredModels() {
        let offered = Set(LocalModelOption.all.map(\.directory.lastPathComponent))
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }
        for folder in folders where !offered.contains(folder.lastPathComponent) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            try? fileManager.removeItem(at: folder)
        }
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
    nonisolated private static func isNeeded(_ path: String) -> Bool {
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

    /// Whether every file of `model` is on disk.
    nonisolated static func isComplete(_ model: LocalModelOption) -> Bool {
        FileManager.default.fileExists(atPath: model.directory.appending(path: completeMarker).path(percentEncoded: false))
    }
}

/// Reports bytes received for one file as it downloads. The async `download(from:delegate:)`
/// doesn't deliver per-chunk write callbacks, so this watches the task's own progress, at most
/// every few megabytes so a multi-gigabyte download doesn't flood the main actor.
private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let onWrite: @Sendable (Int64) -> Void
    private let state = OSAllocatedUnfairLock<(observation: NSKeyValueObservation?, last: Int64)>(
        uncheckedState: (nil, 0)
    )
    private static let step: Int64 = 4 * 1_048_576

    init(onWrite: @escaping @Sendable (Int64) -> Void) {
        self.onWrite = onWrite
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let observation = task.progress.observe(\.completedUnitCount) { [weak self] progress, _ in
            self?.report(progress.completedUnitCount)
        }
        state.withLock { $0.observation = observation }
    }

    private func report(_ received: Int64) {
        let due = state.withLock { state in
            guard received - state.last >= Self.step else { return false }
            state.last = received
            return true
        }
        if due { onWrite(received) }
    }

    deinit {
        state.withLock { $0.observation?.invalidate() }
    }
}
