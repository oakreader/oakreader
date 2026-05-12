// Vendored from https://github.com/mzbac/mlx.embeddings
// Adapted for swift-transformers 1.x and swift-huggingface compatibility.

import Foundation
import Hub
import MLX
import MLXNN
import MLXRandom
import Tokenizers

// MARK: - Model Configuration

struct EmbeddingModelConfiguration: Sendable {
    enum Identifier: Sendable {
        case id(String)
        case directory(URL)
    }

    var id: Identifier
    let tokenizerId: String?

    init(id: String, tokenizerId: String? = nil) {
        self.id = .id(id)
        self.tokenizerId = tokenizerId
    }

    init(directory: URL, tokenizerId: String? = nil) {
        self.id = .directory(directory)
        self.tokenizerId = tokenizerId
    }

    func modelDirectory(hub: HubApi = HubApi()) -> URL {
        switch id {
        case .id(let id):
            let repo = Hub.Repo(id: id)
            return hub.localRepoLocation(repo)
        case .directory(let directory):
            return directory
        }
    }
}

// MARK: - Base Configuration (for reading config.json)

private struct EmbeddingBaseConfiguration: Codable, Sendable {
    let modelType: EmbeddingModelType

    struct Quantization: Codable, Sendable {
        let groupSize: Int
        let bits: Int

        enum CodingKeys: String, CodingKey {
            case groupSize = "group_size"
            case bits
        }
    }

    var quantization: Quantization?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case quantization
    }
}

private struct EmbeddingModelType: RawRepresentable, Codable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    func createModel(configuration: URL) throws -> EmbeddingModelProtocol {
        switch rawValue {
        case "qwen3":
            let config = try JSONDecoder().decode(Qwen3EmbeddingConfiguration.self, from: Data(contentsOf: configuration))
            return Qwen3EmbeddingModel(config)
        default:
            throw EmbeddingLoaderError(message: "Unsupported model type: \(rawValue)")
        }
    }
}

struct EmbeddingLoaderError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Loading

func loadEmbeddingModelSynchronous(modelDirectory: URL) throws -> EmbeddingModelProtocol {
    let configURL = modelDirectory.appending(component: "config.json")
    let baseConfig = try JSONDecoder().decode(EmbeddingBaseConfiguration.self, from: Data(contentsOf: configURL))
    let model = try baseConfig.modelType.createModel(configuration: configURL)

    // Load weights from safetensors
    var weights = [String: MLXArray]()
    let enumerator = FileManager.default.enumerator(at: modelDirectory, includingPropertiesForKeys: nil)!
    for case let url as URL in enumerator {
        if url.pathExtension == "safetensors" {
            let w = try loadArrays(url: url)
            for (key, value) in w {
                weights[key] = value
            }
        }
    }

    weights = model.sanitize(weights: weights)

    // Quantize if needed
    if let quantization = baseConfig.quantization {
        quantize(model: model, groupSize: quantization.groupSize, bits: quantization.bits) { path, _ in
            weights["\(path).scales"] != nil
        }
    }

    let parameters = ModuleParameters.unflattened(weights)
    try model.update(parameters: parameters, verify: [.all])
    eval(model)

    return model
}

/// Prepare model directory — download if needed, or use local cache.
private func prepareEmbeddingModelDirectory(
    hub: HubApi, configuration: EmbeddingModelConfiguration,
    progressHandler: @Sendable @escaping (Progress) -> Void
) async throws -> URL {
    do {
        switch configuration.id {
        case .id(let id):
            let repo = Hub.Repo(id: id)
            let modelFiles = ["*.safetensors", "config.json"]
            return try await hub.snapshot(from: repo, matching: modelFiles, progressHandler: progressHandler)
        case .directory(let directory):
            return directory
        }
    } catch Hub.HubClientError.authorizationRequired {
        return configuration.modelDirectory(hub: hub)
    } catch {
        let nserror = error as NSError
        if nserror.domain == NSURLErrorDomain && nserror.code == NSURLErrorNotConnectedToInternet {
            return configuration.modelDirectory(hub: hub)
        }
        throw error
    }
}

/// Load model and tokenizer into a thread-safe container.
func loadEmbeddingModelContainer(
    hub: HubApi = HubApi(), configuration: EmbeddingModelConfiguration,
    progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
) async throws -> EmbeddingModelContainer {
    let modelDirectory = try await prepareEmbeddingModelDirectory(
        hub: hub, configuration: configuration, progressHandler: progressHandler)
    return try await EmbeddingModelContainer(
        hub: hub, modelDirectory: modelDirectory, configuration: configuration)
}

// MARK: - Tokenizer Loading

func loadEmbeddingTokenizer(configuration: EmbeddingModelConfiguration, hub: HubApi) async throws -> Tokenizer {
    let (tokenizerConfig, tokenizerData) = try await loadEmbeddingTokenizerConfig(
        configuration: configuration, hub: hub)
    return try PreTrainedTokenizer(tokenizerConfig: tokenizerConfig, tokenizerData: tokenizerData)
}

func loadEmbeddingTokenizerConfig(
    configuration: EmbeddingModelConfiguration, hub: HubApi
) async throws -> (Config, Config) {
    let config: LanguageModelConfigurationFromHub

    switch configuration.id {
    case .id(let id):
        do {
            let loaded = LanguageModelConfigurationFromHub(
                modelName: configuration.tokenizerId ?? id, hubApi: hub)
            _ = try await loaded.tokenizerConfig
            config = loaded
        } catch {
            let nserror = error as NSError
            if nserror.domain == NSURLErrorDomain && nserror.code == NSURLErrorNotConnectedToInternet {
                config = LanguageModelConfigurationFromHub(
                    modelFolder: configuration.modelDirectory(hub: hub), hubApi: hub)
            } else {
                throw error
            }
        }
    case .directory(let directory):
        config = LanguageModelConfigurationFromHub(modelFolder: directory, hubApi: hub)
    }

    guard let tokenizerConfig = try await config.tokenizerConfig else {
        throw EmbeddingLoaderError(message: "Missing tokenizer config")
    }
    let tokenizerData = try await config.tokenizerData
    return (tokenizerConfig, tokenizerData)
}
