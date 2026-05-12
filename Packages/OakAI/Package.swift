// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OakAI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OakAI", targets: ["OakAI"])
    ],
    dependencies: [
        .package(path: "../OakAgent"),
    ],
    targets: [
        .target(
            name: "OakAI",
            dependencies: ["OakAgent"],
            path: "Sources/OakAI"
        )
    ],
    swiftLanguageModes: [.v5]
)
