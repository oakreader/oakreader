import Foundation
import AudioCommon

// MARK: - Model Configuration

/// User-facing configuration for which models to use in the voice pipeline.
public struct VoiceModelConfig: Sendable, Codable {
    public var sttModel: String
    public var ttsModel: String
    public var vadModel: String
    /// Optional turn-detector model (e.g. SmartTurn). Nil disables endpoint verification.
    public var turnDetectorModel: String?
    public var ttsVoice: String?
    /// Optional live STT model (Parakeet streaming). Nil disables live transcription.
    public var liveSTTModel: String?

    public init(
        sttModel: String = KnownModels.stt[0].repo,
        ttsModel: String = KnownModels.tts[0].repo,
        vadModel: String = KnownModels.vad[0].repo,
        turnDetectorModel: String? = nil,
        ttsVoice: String? = nil,
        liveSTTModel: String? = KnownModels.liveSTT.first?.repo
    ) {
        self.sttModel = sttModel
        self.ttsModel = ttsModel
        self.vadModel = vadModel
        self.turnDetectorModel = turnDetectorModel
        self.ttsVoice = ttsVoice
        self.liveSTTModel = liveSTTModel
    }

    /// All model repos referenced by this config.
    public var allRepos: [String] {
        var repos = [sttModel, ttsModel, vadModel]
        if let td = turnDetectorModel { repos.append(td) }
        if let live = liveSTTModel { repos.append(live) }
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
    case liveSTT
}

/// Catalog of known/tested models for each component.
public enum KnownModels {
    public static let stt: [ModelOption] = [
        ModelOption(repo: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit", name: "Qwen3-ASR 0.6B (4-bit)", sizeLabel: "~300 MB", component: .stt),
        ModelOption(repo: "aufklarer/Qwen3-ASR-0.6B-MLX-8bit", name: "Qwen3-ASR 0.6B (8-bit)", sizeLabel: "~400 MB", component: .stt),
    ]

    public static let tts: [ModelOption] = [
        ModelOption(repo: "aufklarer/CosyVoice3-0.5B-MLX-4bit", name: "CosyVoice3 0.5B (4-bit)", sizeLabel: "~400 MB", component: .tts),
        ModelOption(repo: "aufklarer/Qwen3-TTS-12Hz-0.6B-Base-MLX-4bit", name: "Qwen3-TTS 0.6B Base (4-bit)", sizeLabel: "~400 MB", component: .tts),
        ModelOption(repo: "aufklarer/Qwen3-TTS-12Hz-0.6B-Base-MLX-8bit", name: "Qwen3-TTS 0.6B Base (8-bit)", sizeLabel: "~700 MB", component: .tts),
        ModelOption(repo: "aufklarer/Kokoro-82M-CoreML", name: "Kokoro 82M (CoreML)", sizeLabel: "~165 MB", component: .tts),
    ]

    public static let vad: [ModelOption] = [
        ModelOption(repo: "aufklarer/Silero-VAD-v5-MLX", name: "Silero VAD v5", sizeLabel: "~2 MB", component: .vad),
    ]

    public static let turnDetector: [ModelOption] = []

    public static let liveSTT: [ModelOption] = [
        ModelOption(repo: "aufklarer/Parakeet-EOU-120M-CoreML-INT8", name: "Parakeet EOU 120M (INT8)", sizeLabel: "~150 MB", component: .liveSTT),
    ]

    /// All known models across all components.
    public static var all: [ModelOption] { stt + tts + vad + turnDetector + liveSTT }

    /// Look up models for a given component.
    public static func models(for component: ModelComponent) -> [ModelOption] {
        switch component {
        case .stt: return stt
        case .tts: return tts
        case .vad: return vad
        case .turnDetector: return turnDetector
        case .liveSTT: return liveSTT
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
    public func isDownloaded(_ repo: String) -> Bool {
        guard let cacheDir = try? HuggingFaceDownloader.getCacheDirectory(for: repo) else {
            return false
        }
        return HuggingFaceDownloader.weightsExist(in: cacheDir)
    }

    /// Download a single model with progress tracking.
    public func download(_ repo: String) async throws {
        setState(repo, .downloading(fractionCompleted: 0))

        do {
            let cacheDir = try HuggingFaceDownloader.getCacheDirectory(for: repo)
            try await HuggingFaceDownloader.downloadWeights(
                modelId: repo,
                to: cacheDir,
                progressHandler: { [weak self] fraction in
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
        guard let cacheDir = try? HuggingFaceDownloader.getCacheDirectory(for: repo) else { return }
        try? FileManager.default.removeItem(at: cacheDir)
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
