// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OakReaderAI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OakReaderAI", targets: ["OakReaderAI"])
    ],
    targets: [
        .target(name: "OakReaderAI", path: "Sources/OakReaderAI")
    ]
)
