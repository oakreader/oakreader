// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OakReader",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(path: "Packages/OakAI"),
        .package(path: "Packages/OakAgent"),
        .package(path: "Packages/OakVoice"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
        .package(url: "https://github.com/stackotter/swift-cmark-gfm", from: "1.0.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),

        .package(url: "https://github.com/open-spaced-repetition/swift-fsrs", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "OakReader",
            dependencies: [
                "OakAgent",
                "OakVoice",
                .product(name: "Textual", package: "textual"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "CMarkGFM", package: "swift-cmark-gfm"),
                .product(name: "Sparkle", package: "Sparkle"),

                .product(name: "FSRS", package: "swift-fsrs"),
            ],
            path: "OakReader",
            exclude: [
                "App/Info.plist",
                "OakReader.entitlements",
                "Resources/Assets.xcassets",
                "Resources/DefaultStamps"
            ],
            resources: [
                .copy("Resources/Assets.xcassets")
            ]
        ),
        .executableTarget(
            name: "oak",
            dependencies: [
                "OakAgent",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "CLI"
        )
    ],
    swiftLanguageModes: [.v5]
)
