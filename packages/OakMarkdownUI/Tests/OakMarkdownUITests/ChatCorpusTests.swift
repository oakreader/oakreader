import XCTest
@testable import OakMarkdownUI
@_spi(Textual) import SwiftUIMath

/// Runs real assistant replies through the renderer and reports what still breaks.
/// Opt-in: set OAK_CHAT_CORPUS to a JSON array of markdown strings.
@MainActor
final class ChatCorpusTests: XCTestCase {

    func testCorpus() throws {
        guard let path = ProcessInfo.processInfo.environment["OAK_CHAT_CORPUS"] else {
            throw XCTSkip("OAK_CHAT_CORPUS not set")
        }
        let messages = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var native = 0, katex = 0, rawFailed = 0
        var failed: [String] = []
        var leftovers: [String] = []
        for markdown in messages {
            for span in MathPlaceholders.protect(markdown).spans {
                // What main draws: SwiftUIMath on the raw source, no rewrite, no fallback.
                let raw = Math.typographicBounds(for: span.latex, fitting: .unspecified,
                    font: .init(name: .latinModern, size: 14), style: span.display ? .display : .text)
                if raw.width <= 0 || MathRoute.hasNonLatinText(span.latex) { rawFailed += 1 }
                if MathRoute.nativeCanDraw(span.latex, display: span.display, fontSize: 14) { native += 1 }
                else if KatexEngine.shared.mathML(for: span.latex, display: span.display) != nil { katex += 1 }
                else { failed.append(span.source) }
            }
            let text = MarkdownAttributedBuilder.attributedString(for: markdown, theme: .chatGPT).string
            for line in text.components(separatedBy: "\n") where line.contains("**") || line.contains("__") {
                leftovers.append(line)
            }
        }
        var report = "messages=\(messages.count) native=\(native) katex=\(katex) rawFailedBefore=\(rawFailed) failed=\(failed.count) leftoverEmphasis=\(leftovers.count)\n"
        report += "--- FAILED MATH\n" + failed.joined(separator: "\n") + "\n--- LEFTOVER EMPHASIS\n" + leftovers.joined(separator: "\n")
        let out = (path as NSString).deletingLastPathComponent + "/report.txt"
        try report.write(toFile: out, atomically: true, encoding: .utf8)
        print(report.prefix(400))
    }
}
