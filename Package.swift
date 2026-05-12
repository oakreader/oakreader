// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OakReader",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(path: "Packages/OakAgent"),
        .package(path: "Packages/OakAI"),
        .package(path: "Packages/OakVoiceAI"),
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
        .package(url: "https://github.com/stackotter/swift-cmark-gfm", from: "1.0.2"),
        .package(url: "https://github.com/SvenTiigi/YouTubePlayerKit.git", from: "2.0.0"),
        .package(url: "https://github.com/skainguyen1412/swift-youtube-transcript.git", from: "1.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "OakReader",
            dependencies: [
                "OakAI",
                "OakVoiceAI",
                .product(name: "Textual", package: "textual"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "CMarkGFM", package: "swift-cmark-gfm"),
                .product(name: "YouTubePlayerKit", package: "YouTubePlayerKit"),
                .product(name: "YoutubeTranscript", package: "swift-youtube-transcript"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "OakReader",
            exclude: ["App/Info.plist", "OakReader.entitlements", "Resources/Assets.xcassets", "Resources/DefaultStamps"],
            resources: [
                .copy("Resources/Assets.xcassets")
            ]
        ),
        .executableTarget(
            name: "oak",
            dependencies: [
                "OakAI",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "CLI"
        )
    ],
    swiftLanguageModes: [.v5]
)
