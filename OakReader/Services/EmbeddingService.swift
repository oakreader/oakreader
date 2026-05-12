import Foundation
import HuggingFace
import MLX
import MLXEmbedders
import MLXLMCommon
import Tokenizers

// MARK: - Hub Integration

/// Downloads model snapshots from HuggingFace Hub.
private struct HubModelDownloader: Downloader {
    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let client = HubClient(cache: .default)
        guard let repoID = Repo.ID(rawValue: id) else {
            throw EmbeddingServiceError.invalidModelId(id)
        }
        return try await client.downloadSnapshot(
            of: repoID,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
    }
}

/// Loads tokenizers from a local directory using swift-transformers.
private struct HubTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerAdapter(upstream: upstream)
    }
}

/// Bridges `Tokenizers.Tokenizer` → `MLXLMCommon.Tokenizer`.
private struct TokenizerAdapter: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
}

private enum EmbeddingServiceError: LocalizedError {
    case invalidModelId(String)

    var errorDescription: String? {
        switch self {
        case .invalidModelId(let id):
            return "Invalid HuggingFace model ID: '\(id)'"
        }
    }
}

// MARK: - Embedding Service

/// On-device embedding service using MLXEmbedders (Qwen3-Embedding).
/// Thread-safe actor that manages model loading and text embedding.
actor EmbeddingService {
    private var container: EmbedderModelContainer?
    private(set) var modelId: String

    init(modelId: String) {
        self.modelId = modelId
    }

    /// Load the embedding model. Call once before embedding.
    func loadModel() async throws {
        let config = ModelConfiguration(id: modelId)
        container = try await EmbedderModelFactory.shared.loadContainer(
            from: HubModelDownloader(),
            using: HubTokenizerLoader(),
            configuration: config
        )
        Log.info(Log.semantic, "Loaded embedding model: \(modelId)")
    }

    /// Embed a batch of texts, returning L2-normalized float vectors.
    func embed(texts: [String]) async throws -> [[Float]] {
        guard let container else {
            throw EmbeddingError.modelNotLoaded
        }

        guard !texts.isEmpty else { return [] }

        let result = try await container.perform { context -> [[Float]] in
            let tokenizer = context.tokenizer
            let model = context.model
            let pooling = context.pooling

            let tokenizedInputs = texts.map {
                tokenizer.encode(text: $0, addSpecialTokens: true)
            }

            let maxLength = min(
                tokenizedInputs.reduce(into: 16) { acc, elem in
                    acc = max(acc, elem.count)
                },
                8192
            )

            let padTokenId = tokenizer.eosTokenId ?? 0
            let paddedInputIds = MLX.stacked(
                tokenizedInputs.map { elem -> MLXArray in
                    let truncated = Array(elem.prefix(maxLength))
                    let paddingCount = maxLength - truncated.count
                    let paddedArray = truncated + Array(repeating: padTokenId, count: paddingCount)
                    return MLXArray(paddedArray)
                }
            )

            let attentionMask = paddedInputIds .!= MLXArray(padTokenId)

            let output = model(
                paddedInputIds,
                positionIds: nil,
                tokenTypeIds: nil,
                attentionMask: attentionMask
            )

            let embeddings = pooling(output, mask: attentionMask, normalize: true)
            eval(embeddings)
            return embeddings.map { $0.asArray(Float.self) }
        }

        // Release intermediate MLX tensors from this batch
        Memory.clearCache()

        return result
    }

    /// Embed a single text.
    func embed(text: String) async throws -> [Float] {
        let results = try await embed(texts: [text])
        guard let first = results.first else {
            throw EmbeddingError.emptyResult
        }
        return first
    }

    enum EmbeddingError: Error, LocalizedError {
        case modelNotLoaded
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded: return "Embedding model not loaded"
            case .emptyResult: return "Embedding produced no results"
            }
        }
    }
}
