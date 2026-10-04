import Foundation

/// A voice's precomputed CaLM attention cache, parsed from one of Kyutai's safetensors files.
///
/// A Pocket TTS "voice" is not an embedding vector. It is the key/value cache the CaLM
/// transformer would hold after attending over a reference recording, exported once so that
/// selecting a voice costs a buffer copy instead of an encode. That is why switching voices is
/// instant and why no reference audio is needed at synthesis time.
///
/// Layout, read from Kyutai's `embeddings_v3/<voice>.safetensors`:
/// ```
/// transformer.layers.{0…5}.self_attn/cache   F32 [2, 1, positions, heads, dHead]
/// transformer.layers.{0…5}.self_attn/offset  I64 [1]            // == positions
/// ```
/// Dimension 0 stacks K and V. `positions` is 125 for the published voices, against the
/// model's 512-slot cache, so the remainder is zero-filled when seeded.
struct PocketTTSVoiceState: Sendable {
    /// Number of valid cache positions. Becomes `voice_offset` for the prompt phase.
    let positions: Int
    let heads: Int
    let dHead: Int
    /// Per-layer key cache, flattened `positions × heads × dHead`.
    let keys: [[Float]]
    /// Per-layer value cache, same shape as ``keys``.
    let values: [[Float]]

    enum LoadError: Error, CustomStringConvertible {
        case unreadable(URL, underlying: Error)
        case truncated(URL)
        case badHeader(URL)
        case missingTensor(URL, String)
        case unexpectedDType(URL, String, String)
        case unexpectedShape(URL, String, [Int])
        case inconsistentLayers(URL)

        var description: String {
            switch self {
            case let .unreadable(url, underlying):
                return "cannot read voice \(url.lastPathComponent): \(underlying)"
            case let .truncated(url):
                return "voice \(url.lastPathComponent) is truncated"
            case let .badHeader(url):
                return "voice \(url.lastPathComponent) has an unreadable safetensors header"
            case let .missingTensor(url, name):
                return "voice \(url.lastPathComponent) is missing tensor \(name)"
            case let .unexpectedDType(url, name, dtype):
                return "voice \(url.lastPathComponent): \(name) is \(dtype), expected F32"
            case let .unexpectedShape(url, name, shape):
                return "voice \(url.lastPathComponent): \(name) has shape \(shape), expected [2, 1, positions, heads, dHead]"
            case let .inconsistentLayers(url):
                return "voice \(url.lastPathComponent): layers disagree on cache dimensions"
            }
        }
    }

    /// Number of CaLM layers the model exposes as state. Fixed by the converted model.
    static let layerCount = 6

    init(contentsOf url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.unreadable(url, underlying: error)
        }

        // safetensors: u64 little-endian header length, then that many bytes of JSON, then the
        // tensor payloads at offsets relative to the end of the header.
        guard data.count > 8 else { throw LoadError.truncated(url) }
        let headerLength = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian })
        guard headerLength > 0, data.count >= 8 + headerLength else { throw LoadError.truncated(url) }

        guard let header = try? JSONSerialization.jsonObject(
            with: data.subdata(in: 8..<(8 + headerLength))
        ) as? [String: Any] else {
            throw LoadError.badHeader(url)
        }
        let payloadStart = 8 + headerLength

        var keys: [[Float]] = []
        var values: [[Float]] = []
        var positions = 0, heads = 0, dHead = 0

        for layer in 0..<Self.layerCount {
            let name = "transformer.layers.\(layer).self_attn/cache"
            guard let entry = header[name] as? [String: Any] else {
                throw LoadError.missingTensor(url, name)
            }
            guard let dtype = entry["dtype"] as? String else {
                throw LoadError.missingTensor(url, "\(name).dtype")
            }
            guard dtype == "F32" else {
                throw LoadError.unexpectedDType(url, name, dtype)
            }
            guard let shape = entry["shape"] as? [Int], shape.count == 5,
                  shape[0] == 2, shape[1] == 1
            else {
                throw LoadError.unexpectedShape(url, name, (entry["shape"] as? [Int]) ?? [])
            }
            guard let offsets = entry["data_offsets"] as? [Int], offsets.count == 2,
                  offsets[0] >= 0, offsets[1] >= offsets[0],
                  payloadStart + offsets[1] <= data.count
            else {
                throw LoadError.truncated(url)
            }

            // All layers must agree, since one set of model state buffers serves them all.
            if layer == 0 {
                positions = shape[2]; heads = shape[3]; dHead = shape[4]
            } else if shape[2] != positions || shape[3] != heads || shape[4] != dHead {
                throw LoadError.inconsistentLayers(url)
            }

            let perSide = positions * heads * dHead
            let floats = data.subdata(in: (payloadStart + offsets[0])..<(payloadStart + offsets[1]))
                .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard floats.count == perSide * 2 else {
                throw LoadError.unexpectedShape(url, name, shape)
            }

            keys.append(Array(floats[0..<perSide]))
            values.append(Array(floats[perSide..<(perSide * 2)]))
        }

        self.positions = positions
        self.heads = heads
        self.dHead = dHead
        self.keys = keys
        self.values = values
    }
}
