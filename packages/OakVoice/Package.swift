// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OakVoice",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OakVoice", targets: ["OakVoice"])
    ],
    targets: [
        .target(
            name: "OakVoice",
            path: "Sources/OakVoice"
        )
    ],
    swiftLanguageModes: [.v5]
)
