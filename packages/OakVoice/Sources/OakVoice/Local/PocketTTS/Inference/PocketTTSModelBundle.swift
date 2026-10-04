import CoreML
import Foundation

/// The three Core ML models and the tokenizer, loaded and ready.
///
/// Constructed from plain file URLs, so this layer has no knowledge of downloads and can be
/// pointed at any directory of compiled models.
///
/// Compute units are assigned per model, and the assignment is measured rather than assumed.
/// All three settings below were benchmarked on an Apple M5 with the per-frame inputs reused:
///
/// | model           | `.cpuOnly` | `.all`     | `.cpuAndGPU` | `.cpuAndNeuralEngine` |
/// |-----------------|-----------:|-----------:|-------------:|----------------------:|
/// | speechGenerator | **0.0104** | 0.0219     | 0.0438       | 0.0306                |
/// | audioDecoder    | 0.0390     | **0.0322** | 0.0443       | 0.1219                |
///
/// Two results are counter-intuitive and worth not "optimising" away later. The speech
/// generator is fastest on the CPU alone, because the model is 100M parameters at batch size 1
/// and the accelerators cost more in dispatch than they return. The Neural Engine is the worst
/// option for the decoder by a factor of four.
///
/// The prompt encoder has no choice at all: its multi-position attention cannot be compiled for
/// the Neural Engine, and asking for `.all` fails with `ANECCompile() FAILED … error -14`.
struct PocketTTSModelBundle {
    let promptEncoder: MLModel
    let speechGenerator: MLModel
    let audioDecoder: MLModel
    let tokenizer: PocketTTSTokenizer

    init(paths: PocketTTSAssetPaths) throws {
        promptEncoder = try Self.load(paths.promptPhase, units: .cpuAndGPU, as: .promptPhase)
        speechGenerator = try Self.load(paths.speechGenerator, units: .cpuOnly, as: .speechGenerator)
        audioDecoder = try Self.load(paths.audioDecoder, units: .all, as: .audioDecoder)
        do {
            tokenizer = try PocketTTSTokenizer(tokenizerJSONURL: paths.tokenizer)
        } catch {
            throw VoiceAgentError.modelNotLoaded("Pocket TTS tokenizer: \(error)")
        }
    }

    private static func load(
        _ url: URL,
        units: MLComputeUnits,
        as artifact: PocketTTSArtifact
    ) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        do {
            return try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw VoiceAgentError.modelNotLoaded("\(artifact.displayName): \(error)")
        }
    }
}
