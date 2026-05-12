// Vendored from https://github.com/mzbac/mlx.embeddings
// Adapted for swift-transformers 1.x compatibility

import Foundation
import Hub
import MLX
import MLXNN
import Tokenizers
import MLXLinalg

// MARK: - Model Container

/// Thread-safe actor container for embedding model + tokenizer.
actor EmbeddingModelContainer {
    let model: EmbeddingModelProtocol
    let tokenizer: Tokenizer

    init(model: EmbeddingModelProtocol, tokenizer: Tokenizer) {
        self.model = model
        self.tokenizer = tokenizer
    }

    init(hub: HubApi, modelDirectory: URL, configuration: EmbeddingModelConfiguration) async throws {
        self.model = try loadEmbeddingModelSynchronous(modelDirectory: modelDirectory)
        let (tokenizerConfig, tokenizerData) = try await loadEmbeddingTokenizerConfig(
            configuration: configuration, hub: hub)
        self.tokenizer = try PreTrainedTokenizer(
            tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
    }

    /// Perform an action on the model and tokenizer.
    /// Callers must `eval()` any `MLXArray` before returning.
    func perform<R>(_ action: @Sendable (EmbeddingModelProtocol, Tokenizer) throws -> R) rethrows -> R {
        try action(model, tokenizer)
    }
}

// MARK: - Model Output

struct EmbeddingModelOutput {
    let hiddenStates: MLXArray?
    let poolerOutput: MLXArray?
    let textEmbeds: MLXArray
}

// MARK: - Model Protocol

protocol EmbeddingModelProtocol: Module {
    func callAsFunction(
        _ inputs: MLXArray, positionIds: MLXArray?, tokenTypeIds: MLXArray?,
        attentionMask: MLXArray?
    ) -> EmbeddingModelOutput

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray]
}

extension EmbeddingModelProtocol {
    func callAsFunction(
        _ inputs: MLXArray, positionIds: MLXArray? = nil, tokenTypeIds: MLXArray? = nil,
        attentionMask: MLXArray? = nil
    ) -> EmbeddingModelOutput {
        callAsFunction(inputs, positionIds: positionIds, tokenTypeIds: tokenTypeIds,
                       attentionMask: attentionMask)
    }
}

// MARK: - Pooling

func meanPooling(lastHiddenState: MLXArray, attentionMask: MLXArray) -> MLXArray {
    let expandedMask = attentionMask.expandedDimensions(axes: [-1])
    let broadcastMask = broadcast(expandedMask, to: lastHiddenState.shape).asType(.float32)
    let sumHiddenState = sum(lastHiddenState * broadcastMask, axes: [1])
    let sumMask = sum(broadcastMask, axes: [1])
    let safeSumMask = MLX.maximum(sumMask, MLXArray(1e-9))
    return sumHiddenState / safeSumMask
}

func normalizeEmbeddings(_ embeddings: MLXArray) -> MLXArray {
    let normValue = norm(embeddings, ord: 2, axis: -1, keepDims: true)
    let safeNormValue = MLX.maximum(normValue, MLXArray(1e-9))
    return embeddings / safeNormValue
}

func lastTokenPooling(lastHiddenState: MLXArray, attentionMask: MLXArray) -> MLXArray {
    let sequenceLengths = sum(attentionMask, axes: [1]) - 1
    let batchSize = lastHiddenState.shape[0]
    let lastTokenIndices = maximum(sequenceLengths, MLXArray(0))
    let batchIndices = MLXArray.arange(batchSize)
    return lastHiddenState[batchIndices, lastTokenIndices]
}
