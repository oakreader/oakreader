// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OakEditor",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "OakEditor", targets: ["OakEditor"])
    ],
    dependencies: [
        .package(path: "../OakAI"),
    ],
    targets: [
        .target(
            name: "OakEditor",
            dependencies: ["OakAI"],
            path: "Sources/OakEditor",
            resources: [
                // The Milkdown (Crepe) WYSIWYG editor, built from ../web by Vite.
                .copy("Resources/Milkdown.bundle")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
