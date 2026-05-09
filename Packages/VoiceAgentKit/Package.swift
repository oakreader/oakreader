// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceAgentKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VoiceAgentKit", targets: ["VoiceAgentKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", branch: "main"),
        .package(path: "../OakReaderAI"),
    ],
    targets: [
        .target(
            name: "VoiceAgentKit",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                "OakReaderAI",
            ],
            path: "Sources/VoiceAgentKit"
        )
    ],
    swiftLanguageModes: [.v5]
)
