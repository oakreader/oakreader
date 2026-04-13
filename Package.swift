// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OakReader",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(path: "Packages/OakReaderAI")
    ],
    targets: [
        .executableTarget(
            name: "OakReader",
            dependencies: ["OakReaderAI"],
            path: "OakReader",
            exclude: ["App/Info.plist", "OakReader.entitlements", "Resources/Assets.xcassets", "Resources/DefaultStamps"],
            resources: [
                .copy("Resources/Assets.xcassets")
            ]
        ),
        .executableTarget(
            name: "oakreader-chat",
            dependencies: ["OakReaderAI"],
            path: "CLI"
        )
    ]
)
