// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OakAgent",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OakAgent", targets: ["OakAgent"])
    ],
    targets: [
        .target(name: "OakAgent", path: "Sources/OakAgent")
    ],
    swiftLanguageModes: [.v5]
)
