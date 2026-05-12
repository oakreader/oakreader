import Foundation
import MLX

/// On-device embedding service using vendored mlx.embeddings code (Qwen3-Embedding).
/// Thread-safe actor that manages model loading and text embedding.
actor EmbeddingService {
    private var container: EmbeddingModelContainer?
    private(set) var modelId: String

    init(modelId: String) {
        self.modelId = modelId
    }

    /// Load the embedding model. Call once before embedding.
    func loadModel() async throws {
        let config = EmbeddingModelConfiguration(id: modelId)
        container = try await loadEmbeddingModelContainer(configuration: config)
        Log.info(Log.semantic, "Loaded embedding model: \(modelId)")
    }

    /// Embed a batch of texts, returning L2-normalized float vectors.
    func embed(texts: [String]) async throws -> [[Float]] {
        guard let container else {
            throw EmbeddingError.modelNotLoaded
        }

        guard !texts.isEmpty else { return [] }

        return await container.perform { model, tokenizer -> [[Float]] in
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

            // textEmbeds is already L2-normalized by the Qwen3 model
            let embeddings = output.textEmbeds
            eval(embeddings)
            return embeddings.map { $0.asArray(Float.self) }
        }
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
