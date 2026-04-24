// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OakReaderAI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OakReaderAI", targets: ["OakReaderAI"])
    ],
    targets: [
        .target(name: "OakReaderAI", path: "Sources/OakReaderAI")
    ],
    swiftLanguageModes: [.v5]
)
