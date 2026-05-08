// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceAgentKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoiceAgentKit", targets: ["VoiceAgentKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/soniqo/speech-swift", branch: "main"),
        .package(path: "../OakReaderAI"),
    ],
    targets: [
        .target(
            name: "VoiceAgentKit",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "Qwen3TTS", package: "speech-swift"),
                .product(name: "CosyVoiceTTS", package: "speech-swift"),
                .product(name: "KokoroTTS", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
                .product(name: "ParakeetStreamingASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift"),
                "OakReaderAI",
            ],
            path: "Sources/VoiceAgentKit"
        )
    ],
    swiftLanguageModes: [.v5]
)
