import Foundation
import HuggingFace
import MLXAudioCore

// MARK: - Voice Provider Type

/// Whether a pipeline component uses on-device MLX models or a cloud provider.
public enum VoiceProviderType: String, Sendable, Codable, CaseIterable {
    case onDevice = "on_device"
    case elevenLabs = "elevenlabs"

    public var displayName: String {
        switch self {
        case .onDevice: return "On-Device"
        case .elevenLabs: return "ElevenLabs Cloud"
        }
    }
}

// MARK: - Model Configuration

/// User-facing configuration for which models to use in the voice pipeline.
public struct VoiceModelConfig: Sendable, Codable {
    public var sttModel: String
    public var ttsModel: String
    public var vadModel: String
    /// Optional turn-detector model (e.g. SmartTurn). Nil disables endpoint verification.
    public var turnDetectorModel: String?
    public var ttsVoice: String?
    /// Which provider to use for STT (on-device MLX or cloud).
    public var sttProvider: VoiceProviderType
    /// Which provider to use for TTS (on-device MLX or cloud).
    public var ttsProvider: VoiceProviderType

    public init(
        sttModel: String = KnownModels.stt[0].repo,
        ttsModel: String = KnownModels.tts[0].repo,
        vadModel: String = KnownModels.vad[0].repo,
        turnDetectorModel: String? = KnownModels.turnDetector.first?.repo,
        ttsVoice: String? = nil,
        sttProvider: VoiceProviderType = .onDevice,
        ttsProvider: VoiceProviderType = .onDevice
    ) {
        self.sttModel = sttModel
        self.ttsModel = ttsModel
        self.vadModel = vadModel
        self.turnDetectorModel = turnDetectorModel
        self.ttsVoice = ttsVoice
        self.sttProvider = sttProvider
        self.ttsProvider = ttsProvider
    }

    /// All on-device model repos referenced by this config (excludes cloud providers).
    public var allRepos: [String] {
        var repos = [String]()
        if sttProvider == .onDevice { repos.append(sttModel) }
        if ttsProvider == .onDevice { repos.append(ttsModel) }
        repos.append(vadModel) // VAD is always on-device
        if let td = turnDetectorModel { repos.append(td) }
        return repos
    }
}

// MARK: - Known Model Catalog

/// Metadata for a known model option.
public struct ModelOption: Sendable, Identifiable {
    public let repo: String
    public let name: String
    public let sizeLabel: String
    public let component: ModelComponent

    public var id: String { repo }

    public init(repo: String, name: String, sizeLabel: String, component: ModelComponent) {
        self.repo = repo
        self.name = name
        self.sizeLabel = sizeLabel
        self.component = component
    }
}

/// Which pipeline component a model serves.
public enum ModelComponent: String, Sendable, Codable {
    case stt
    case tts
    case vad
    case turnDetector
}

/// Catalog of known/tested models for each component.
public enum KnownModels {
    public static let stt: [ModelOption] = [
        ModelOption(repo: "mlx-community/Qwen3-ASR-0.6B-4bit", name: "Qwen3-ASR 0.6B (4-bit)", sizeLabel: "~300 MB", component: .stt),
        ModelOption(repo: "mlx-community/Qwen3-ASR-0.6B-8bit", name: "Qwen3-ASR 0.6B (8-bit)", sizeLabel: "~400 MB", component: .stt),
        ModelOption(repo: "mlx-community/Qwen3-ASR-1.7B-4bit", name: "Qwen3-ASR 1.7B (4-bit)", sizeLabel: "~600 MB", component: .stt),
        ModelOption(repo: "mlx-community/Qwen3-ASR-1.7B-8bit", name: "Qwen3-ASR 1.7B (8-bit)", sizeLabel: "~1 GB", component: .stt),
    ]

    public static let tts: [ModelOption] = [
        ModelOption(repo: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit", name: "Qwen3-TTS 0.6B Base (4-bit)", sizeLabel: "~400 MB", component: .tts),
        ModelOption(repo: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", name: "Qwen3-TTS 0.6B Base (8-bit)", sizeLabel: "~700 MB", component: .tts),
        ModelOption(repo: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit", name: "Qwen3-TTS 1.7B Base (8-bit)", sizeLabel: "~2 GB", component: .tts),
        ModelOption(repo: "mlx-community/Kokoro-82M-bf16", name: "Kokoro 82M (bf16)", sizeLabel: "~165 MB", component: .tts),
        ModelOption(repo: "mlx-community/Kokoro-82M-4bit", name: "Kokoro 82M (4-bit)", sizeLabel: "~40 MB", component: .tts),
        ModelOption(repo: "mlx-community/chatterbox-turbo-fp16", name: "Chatterbox Turbo (voice clone)", sizeLabel: "~700 MB", component: .tts),
        ModelOption(repo: "mlx-community/Chatterbox-TTS-fp16", name: "Chatterbox Regular (voice clone)", sizeLabel: "~1 GB", component: .tts),
    ]

    public static let vad: [ModelOption] = [
        ModelOption(repo: "mlx-community/silero-vad", name: "Silero VAD", sizeLabel: "~2 MB", component: .vad),
    ]

    public static let turnDetector: [ModelOption] = [
        ModelOption(repo: "mlx-community/smart-turn-v3", name: "SmartTurn v3 (endpoint)", sizeLabel: "~30 MB", component: .turnDetector),
    ]

    /// All known models across all components.
    public static var all: [ModelOption] { stt + tts + vad + turnDetector }

    /// Look up models for a given component.
    public static func models(for component: ModelComponent) -> [ModelOption] {
        switch component {
        case .stt: return stt
        case .tts: return tts
        case .vad: return vad
        case .turnDetector: return turnDetector
        }
    }
}

// MARK: - Model Manager

/// Manages model downloading, caching, and load state tracking.
public actor ModelManager {
    /// Shared singleton for consistent state tracking across the app.
    public static let shared = ModelManager()

    /// Download/load state for a model.
    public enum ModelState: Sendable {
        case notDownloaded
        case downloading(fractionCompleted: Double)
        case downloaded
        case loading
        case ready
        case failed(String)
    }

    private var states: [String: ModelState] = [:]
    private var stateContinuation: AsyncStream<(String, ModelState)>.Continuation?

    /// Stream of state changes for UI observation. Emits `(repo, newState)` pairs.
    public nonisolated let stateChanges: AsyncStream<(String, ModelState)>

    public init() {
        var continuation: AsyncStream<(String, ModelState)>.Continuation!
        self.stateChanges = AsyncStream { continuation = $0 }
        self.stateContinuation = continuation
    }

    /// Get the current state for a model repository.
    /// If no explicit state has been set, checks the disk cache.
    public func state(for repo: String) -> ModelState {
        if let known = states[repo] { return known }
        // Check disk cache for already-downloaded models
        if isDownloaded(repo) {
            states[repo] = .downloaded
            return .downloaded
        }
        return .notDownloaded
    }

    /// Check whether a model is already cached locally.
    /// Checks both the mlx-audio cache dir and the Hub repo snapshot dir.
    public func isDownloaded(_ repo: String) -> Bool {
        // Check mlx-audio cache directory
        let cache = HubCache.default
        let modelSubdir = repo.replacingOccurrences(of: "/", with: "_")
        let mlxAudioDir = cache.cacheDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(modelSubdir)

        if hasSafetensors(in: mlxAudioDir) { return true }

        // Check Hub repo snapshot directory
        if let repoID = Repo.ID(rawValue: repo) {
            let hubDir = cache.repoDirectory(repo: repoID, kind: .model)
            // Snapshots are in subdirectories
            if let snapshots = try? FileManager.default.contentsOfDirectory(
                at: hubDir.appendingPathComponent("snapshots"),
                includingPropertiesForKeys: nil
            ) {
                for snapshotDir in snapshots {
                    if hasSafetensors(in: snapshotDir) { return true }
                }
            }
            // Also check the repo dir itself (flat layout)
            if hasSafetensors(in: hubDir) { return true }
        }

        return false
    }

    private func hasSafetensors(in directory: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        )
        return files?.contains { file in
            guard file.pathExtension == "safetensors" else { return false }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size > 0
        } ?? false
    }

    /// Custom HuggingFace endpoint (e.g. "https://hf-mirror.com").
    /// Set this before downloading to use a mirror. Nil = default (huggingface.co).
    public var endpointURL: URL?

    /// Download a single model with progress tracking.
    public func download(_ repo: String) async throws {
        guard let repoID = Repo.ID(rawValue: repo) else {
            throw VoiceAgentError.modelNotLoaded("Invalid repository ID: \(repo)")
        }

        setState(repo, .downloading(fractionCompleted: 0))

        do {
            let client: HubClient
            if let endpoint = endpointURL {
                client = HubClient(host: endpoint, cache: .default)
            } else {
                client = HubClient(cache: .default)
            }
            _ = try await ModelUtils.resolveOrDownloadModel(
                client: client,
                cache: .default,
                repoID: repoID,
                requiredExtension: "safetensors",
                progressHandler: { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    // Update both the internal dictionary and the stream
                    // so any path (stream observer or state query) sees current progress.
                    Task { await self?.setState(repo, .downloading(fractionCompleted: fraction)) }
                }
            )
            setState(repo, .downloaded)
        } catch {
            setState(repo, .failed(error.localizedDescription))
            throw error
        }
    }

    /// Download all models required by a config. Returns when all complete.
    public func downloadAll(_ config: VoiceModelConfig) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for repo in config.allRepos {
                if !isDownloaded(repo) {
                    group.addTask { try await self.download(repo) }
                }
            }
            try await group.waitForAll()
        }
    }

    /// Delete a cached model.
    public func delete(_ repo: String) {
        let cache = HubCache.default
        let modelSubdir = repo.replacingOccurrences(of: "/", with: "_")
        let modelDir = cache.cacheDirectory
            .appendingPathComponent("mlx-audio")
            .appendingPathComponent(modelSubdir)
        try? FileManager.default.removeItem(at: modelDir)

        if let repoID = Repo.ID(rawValue: repo) {
            let hubRepoDir = cache.repoDirectory(repo: repoID, kind: .model)
            try? FileManager.default.removeItem(at: hubRepoDir)
        }

        setState(repo, .notDownloaded)
    }

    // MARK: - Load state tracking (used by providers)

    public func setLoading(_ repo: String) {
        setState(repo, .loading)
    }

    public func setReady(_ repo: String) {
        setState(repo, .ready)
    }

    public func setFailed(_ repo: String, error: Error) {
        setState(repo, .failed(error.localizedDescription))
    }

    // MARK: - Internal

    private func setState(_ repo: String, _ state: ModelState) {
        states[repo] = state
        stateContinuation?.yield((repo, state))
    }
}
