// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OakAI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OakAI", targets: ["OakAI"])
    ],
    targets: [
        .target(
            name: "OakAI",
            path: "Sources/OakAI"
        )
    ],
    swiftLanguageModes: [.v5]
)
