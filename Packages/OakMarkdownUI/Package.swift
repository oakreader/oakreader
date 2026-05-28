// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OakMarkdownUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OakMarkdownUI", targets: ["OakMarkdownUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
        // Same math engine Dia uses (SwiftMath → MTMathUILabel / MTMathImage, CoreText).
        // Gives NSView + NSImage so inline math can embed in the NSTextView text flow.
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.0"),
        // Same markdown parser Dia uses (Apple swift-markdown → MarkupVisitor → NSAttributedString).
        // Apple ships no semver tags; the release branch builds with the released toolchain.
        .package(url: "https://github.com/apple/swift-markdown.git", branch: "swift-markdown-0.8"),
    ],
    targets: [
        .target(
            name: "OakMarkdownUI",
            dependencies: [
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "SwiftMath", package: "SwiftMath"),
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
    ]
)
