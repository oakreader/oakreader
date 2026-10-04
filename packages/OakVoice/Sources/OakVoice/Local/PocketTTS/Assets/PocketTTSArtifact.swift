import Foundation

/// One downloadable Pocket TTS artifact: what it is, where it comes from, how to check it.
///
/// Pure data. Nothing here touches the disk or the network, so the hosting decisions below can
/// be reviewed in one place without reading the installer.
public enum PocketTTSArtifact: String, CaseIterable, Sendable {
    case promptPhase = "prompt_phase"
    case speechGenerator = "calm_stateful"
    case audioDecoder = "mimi_stateful"
    case tokenizer = "tokenizer"

    /// Name shown next to a progress bar while downloading.
    public var displayName: String {
        switch self {
        case .promptPhase: return "Prompt encoder"
        case .speechGenerator: return "Speech generator"
        case .audioDecoder: return "Audio decoder"
        case .tokenizer: return "Text tokenizer"
        }
    }

    /// Approximate download size, for the settings row before anything is fetched.
    public var approximateBytes: Int64 {
        switch self {
        case .promptPhase: return 110_000_000
        case .speechGenerator: return 161_000_000
        case .audioDecoder: return 20_000_000
        case .tokenizer: return 245_000
        }
    }

    /// Core ML packages arrive zipped and need compiling; the tokenizer is a plain file.
    var needsCompilation: Bool { self != .tokenizer }

    /// Filename once installed.
    var installedName: String {
        needsCompilation ? "\(rawValue).mlmodelc" : "tokenizer.json"
    }

    /// SHA-256 of the bytes as downloaded, before any unpacking.
    ///
    /// Checked because a truncated download otherwise surfaces much later as an
    /// unintelligible Core ML compile failure rather than "the file is wrong".
    var expectedSHA256: String {
        switch self {
        case .promptPhase:
            return "2f85b6c542da3bc8125782322e19089463787beddd866ad7de3c22525959cc7f"
        case .speechGenerator:
            return "4efed58521ee32444febceb98a9331a154ed2fe7c93667d301a747b0c5a7d08d"
        case .audioDecoder:
            return "d74980e44fd8974fe0b47dd69e4e92bd980f73c110a5195293e544374282196f"
        case .tokenizer:
            return "f498428e1eafee50492f7be13dc9bfafcfc12e508cd0eb1b01c92ecd5d8c6687"
        }
    }

    var remoteURL: URL {
        switch self {
        case .tokenizer:
            return Hosting.kyutai.appendingPathComponent("tokenizer.json")
        default:
            return Hosting.coreML.appendingPathComponent("\(rawValue).mlpackage.zip")
        }
    }

    /// Where the voice caches live, which is Kyutai's own repository.
    static func remoteVoiceURL(id: String) -> URL {
        Hosting.kyutai
            .appendingPathComponent("embeddings_v3")
            .appendingPathComponent("\(id).safetensors")
    }

    /// Download origins, kept together so they are easy to repoint.
    enum Hosting {
        /// A third party's Core ML conversion of Kyutai's weights, published CC-BY-4.0.
        ///
        /// Mirror this to our own bucket before shipping. The licence permits it, and leaving
        /// an individual's Hugging Face repository on the runtime path means read-aloud breaks
        /// for every user if they rename or delete it.
        static let coreML = URL(
            string: "https://huggingface.co/slaughters85j/pocket-tts-coreml/resolve/main"
        )!

        /// Kyutai's own CC-BY-4.0 tokenizer and voice caches.
        static let kyutai = URL(
            string: "https://huggingface.co/kyutai/pocket-tts-without-voice-cloning/resolve/main"
        )!
    }
}

/// Resolved on-disk locations of everything the engine needs.
///
/// The inference layer takes this and never learns that a download exists.
public struct PocketTTSAssetPaths: Sendable {
    public let promptPhase: URL
    public let speechGenerator: URL
    public let audioDecoder: URL
    public let tokenizer: URL
}
