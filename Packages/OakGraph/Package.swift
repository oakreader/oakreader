// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OakGraph",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OakGraph", targets: ["OakGraph"])
    ],
    targets: [
        .target(name: "OakGraph", path: "Sources/OakGraph")
    ],
    swiftLanguageModes: [.v5]
)
