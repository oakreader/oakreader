// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OakReader",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(path: "Packages/OakReaderAI"),
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "OakReader",
            dependencies: ["OakReaderAI", .product(name: "Textual", package: "textual"), .product(name: "GRDB", package: "GRDB.swift")],
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
    ],
    swiftLanguageModes: [.v5]
)
