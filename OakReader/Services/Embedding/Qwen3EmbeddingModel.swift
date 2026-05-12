// Vendored from https://github.com/mzbac/mlx.embeddings
// Qwen3 embedding model architecture for on-device inference via MLX.

import Foundation
import MLX
import MLXFast
import MLXLinalg
import MLXNN

// MARK: - Attention Mask (replaces MLXLMCommon dependency)

/// Create a causal attention mask for the transformer.
private func createEmbeddingAttentionMask(h: MLXArray, cache: [EmbeddingKVCache]?) -> MLXArray? {
    let T = h.dim(1)
    if T > 1 {
        let indices = MLXArray.arange(T)
        var mask = indices[.newAxis, 0...] .< indices[0..., .newAxis] + 1
        mask = mask.asType(h.dtype)
        return mask
    }
    return nil
}

// MARK: - KV Cache (simplified, no external dependency)

class EmbeddingKVCache {
    var keys: MLXArray?
    var values: MLXArray?
    var offset: Int { keys?.dim(2) ?? 0 }

    func update(keys newKeys: MLXArray, values newValues: MLXArray) -> (MLXArray, MLXArray) {
        if let existingKeys = keys, let existingValues = values {
            keys = concatenated([existingKeys, newKeys], axis: 2)
            values = concatenated([existingValues, newValues], axis: 2)
        } else {
            keys = newKeys
            values = newValues
        }
        return (keys!, values!)
    }
}

// MARK: - Qwen3 Configuration

struct Qwen3EmbeddingConfiguration: Codable, Sendable {
    var hiddenSize: Int
    var hiddenLayers: Int
    var intermediateSize: Int
    var attentionHeads: Int
    var rmsNormEps: Float
    var vocabularySize: Int
    var kvHeads: Int
    var ropeTheta: Float = 1_000_000
    var headDim: Int
    var ropeScaling: [String: StringOrNumber]? = nil
    var tieWordEmbeddings = false
    var maxPositionEmbeddings: Int = 32768

    enum CodingKeys: String, CodingKey {
        case hiddenSize = "hidden_size"
        case hiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case rmsNormEps = "rms_norm_eps"
        case vocabularySize = "vocab_size"
        case kvHeads = "num_key_value_heads"
        case ropeTheta = "rope_theta"
        case headDim = "head_dim"
        case ropeScaling = "rope_scaling"
        case tieWordEmbeddings = "tie_word_embeddings"
        case maxPositionEmbeddings = "max_position_embeddings"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hiddenSize = try container.decode(Int.self, forKey: .hiddenSize)
        self.hiddenLayers = try container.decode(Int.self, forKey: .hiddenLayers)
        self.intermediateSize = try container.decode(Int.self, forKey: .intermediateSize)
        self.attentionHeads = try container.decode(Int.self, forKey: .attentionHeads)
        self.rmsNormEps = try container.decode(Float.self, forKey: .rmsNormEps)
        self.vocabularySize = try container.decode(Int.self, forKey: .vocabularySize)
        self.kvHeads = try container.decode(Int.self, forKey: .kvHeads)
        self.ropeTheta = try container.decodeIfPresent(Float.self, forKey: .ropeTheta) ?? 1_000_000
        self.headDim = try container.decode(Int.self, forKey: .headDim)
        self.ropeScaling = try container.decodeIfPresent([String: StringOrNumber].self, forKey: .ropeScaling)
        self.tieWordEmbeddings = try container.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? false
        self.maxPositionEmbeddings = try container.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings) ?? 32768
    }
}

// MARK: - StringOrNumber (config helper)

enum StringOrNumber: Codable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case float(Float)
    case ints([Int])
    case floats([Float])

    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer()
        if let v = try? values.decode(Int.self) { self = .int(v) }
        else if let v = try? values.decode(Float.self) { self = .float(v) }
        else if let v = try? values.decode([Int].self) { self = .ints(v) }
        else if let v = try? values.decode([Float].self) { self = .floats(v) }
        else { self = .string(try values.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .float(let v): try container.encode(v)
        case .ints(let v): try container.encode(v)
        case .floats(let v): try container.encode(v)
        }
    }

    func asFloat() -> Float? {
        switch self {
        case .float(let v): return v
        case .int(let v): return Float(v)
        default: return nil
        }
    }
}

// MARK: - Qwen3 Attention

private class Qwen3Attention: Module {
    let args: Qwen3EmbeddingConfiguration
    let scale: Float

    @ModuleInfo(key: "q_proj") var wq: Linear
    @ModuleInfo(key: "k_proj") var wk: Linear
    @ModuleInfo(key: "v_proj") var wv: Linear
    @ModuleInfo(key: "o_proj") var wo: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    let rope: RoPE

    init(_ args: Qwen3EmbeddingConfiguration) {
        self.args = args
        let dim = args.hiddenSize
        let heads = args.attentionHeads
        let kvHeads = args.kvHeads
        let headDim = args.headDim
        self.scale = pow(Float(headDim), -0.5)

        _wq.wrappedValue = Linear(dim, heads * headDim, bias: false)
        _wk.wrappedValue = Linear(dim, kvHeads * headDim, bias: false)
        _wv.wrappedValue = Linear(dim, kvHeads * headDim, bias: false)
        _wo.wrappedValue = Linear(heads * headDim, dim, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: args.rmsNormEps)

        let ropeScale: Float
        if let ropeScaling = args.ropeScaling,
           ropeScaling["type"] == .string("linear"),
           let factor = ropeScaling["factor"]?.asFloat() {
            ropeScale = 1 / factor
        } else {
            ropeScale = 1
        }
        self.rope = RoPE(dimensions: headDim, traditional: false, base: args.ropeTheta, scale: ropeScale)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray? = nil, cache: EmbeddingKVCache? = nil) -> MLXArray {
        let (B, L) = (x.dim(0), x.dim(1))
        var queries = qNorm(wq(x).reshaped(B, L, args.attentionHeads, -1)).transposed(0, 2, 1, 3)
        var keys = kNorm(wk(x).reshaped(B, L, args.kvHeads, -1)).transposed(0, 2, 1, 3)
        var values = wv(x).reshaped(B, L, args.kvHeads, -1).transposed(0, 2, 1, 3)

        if let cache {
            queries = rope(queries, offset: cache.offset)
            keys = rope(keys, offset: cache.offset)
            (keys, values) = cache.update(keys: keys, values: values)
        } else {
            queries = rope(queries)
            keys = rope(keys)
        }

        let output = MLXFast.scaledDotProductAttention(
            queries: queries, keys: keys, values: values, scale: scale, mask: mask
        ).transposed(0, 2, 1, 3).reshaped(B, L, -1)

        return wo(output)
    }
}

// MARK: - Qwen3 MLP

private class Qwen3MLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    @ModuleInfo(key: "up_proj") var up: Linear

    init(dimensions: Int, hiddenDimensions: Int) {
        _gate.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
        _down.wrappedValue = Linear(hiddenDimensions, dimensions, bias: false)
        _up.wrappedValue = Linear(dimensions, hiddenDimensions, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        down(silu(gate(x)) * up(x))
    }
}

// MARK: - Qwen3 Transformer Block

private class Qwen3TransformerBlock: Module {
    @ModuleInfo(key: "self_attn") var attention: Qwen3Attention
    let mlp: Qwen3MLP
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: RMSNorm

    init(_ args: Qwen3EmbeddingConfiguration) {
        _attention.wrappedValue = Qwen3Attention(args)
        self.mlp = Qwen3MLP(dimensions: args.hiddenSize, hiddenDimensions: args.intermediateSize)
        _inputLayerNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
        _postAttentionLayerNorm.wrappedValue = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray? = nil, cache: EmbeddingKVCache? = nil) -> MLXArray {
        let r = attention(inputLayerNorm(x), mask: mask, cache: cache)
        let h = x + r
        return h + mlp(postAttentionLayerNorm(h))
    }
}

// MARK: - Qwen3 Inner Model

private class Qwen3ModelInner: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    fileprivate let layers: [Qwen3TransformerBlock]
    let norm: RMSNorm

    init(_ args: Qwen3EmbeddingConfiguration) {
        precondition(args.vocabularySize > 0)
        _embedTokens.wrappedValue = Embedding(embeddingCount: args.vocabularySize, dimensions: args.hiddenSize)
        self.layers = (0..<args.hiddenLayers).map { _ in Qwen3TransformerBlock(args) }
        self.norm = RMSNorm(dimensions: args.hiddenSize, eps: args.rmsNormEps)
    }

    func callAsFunction(_ inputs: MLXArray, cache: [EmbeddingKVCache]? = nil) -> MLXArray {
        var h = embedTokens(inputs)
        let mask: MLXArray? = createEmbeddingAttentionMask(h: h, cache: cache)
        for (i, layer) in layers.enumerated() {
            h = layer(h, mask: mask, cache: cache?[i])
        }
        return norm(h)
    }
}

// MARK: - Qwen3 Embedding Model

class Qwen3EmbeddingModel: Module, EmbeddingModelProtocol {
    @ModuleInfo(key: "model") private var model: Qwen3ModelInner

    init(_ args: Qwen3EmbeddingConfiguration) {
        self._model.wrappedValue = Qwen3ModelInner(args)
    }

    func callAsFunction(
        _ inputIds: MLXArray, positionIds: MLXArray? = nil, tokenTypeIds: MLXArray? = nil,
        attentionMask: MLXArray? = nil
    ) -> EmbeddingModelOutput {
        let out = model(inputIds, cache: nil)
        var textEmbeds = lastTokenPooling(lastHiddenState: out, attentionMask: attentionMask!)
        textEmbeds = normalizeEmbeddings(textEmbeds)
        return EmbeddingModelOutput(hiddenStates: out, poolerOutput: nil, textEmbeds: textEmbeds)
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var sanitized = [String: MLXArray]()
        for (key, value) in weights {
            if key.contains("self_attn.rotary_emb.inv_freq") || key.contains("lm_head") { continue }
            var newKey = key
            if !newKey.hasPrefix("model.") { newKey = "model." + newKey }
            sanitized[newKey] = value
        }
        return sanitized
    }
}
