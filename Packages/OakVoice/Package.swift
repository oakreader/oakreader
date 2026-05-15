// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OakVoice",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OakVoice", targets: ["OakVoice"])
    ],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", branch: "main"),
    ],
    targets: [
        .target(
            name: "OakVoice",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                .product(name: "MLXAudioVAD", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
            ],
            path: "Sources/OakVoice"
        )
    ],
    swiftLanguageModes: [.v5]
)
