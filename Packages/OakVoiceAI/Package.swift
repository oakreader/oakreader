// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OakVoiceAI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OakVoiceAI", targets: ["OakVoiceAI"])
    ],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", branch: "main"),
        .package(path: "../OakAgent"),
    ],
    targets: [
        .target(
            name: "OakVoiceAI",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                "OakAgent",
            ],
            path: "Sources/OakVoiceAI"
        )
    ],
    swiftLanguageModes: [.v5]
)
