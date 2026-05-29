// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OakMarkdownUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OakMarkdownUI", targets: ["OakMarkdownUI"]),
    ],
    dependencies: [
        // All three are already in the OakReader graph — OakMarkdownUI introduces NO new package.
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
        .package(url: "https://github.com/gonzalezreal/swiftui-math", from: "0.1.0"),
        .package(url: "https://github.com/stackotter/swift-cmark-gfm", from: "1.0.2"),
    ],
    targets: [
        .target(
            name: "OakMarkdownUI",
            dependencies: [
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "SwiftUIMath", package: "swiftui-math"),
                .product(name: "CMarkGFM", package: "swift-cmark-gfm"),
            ]
        ),
    ]
)
