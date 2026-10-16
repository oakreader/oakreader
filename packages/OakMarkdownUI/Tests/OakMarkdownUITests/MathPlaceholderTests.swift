import XCTest
@testable import OakMarkdownUI

/// Math is swapped out before cmark parses, so markdown syntax inside a formula
/// stays LaTeX. Code spans and fences keep their dollars.
@MainActor
final class MathPlaceholderTests: XCTestCase {

    private func spans(_ markdown: String) -> [MathSpan] {
        MathPlaceholders.protect(markdown).spans
    }

    private func attachmentCount(_ text: NSAttributedString) -> Int {
        var count = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value != nil { count += 1 }
        }
        return count
    }

    /// Found in a real chat: a price, then a citation on the same line.
    func testPriceBeforeCitationIsNotAFormula() {
        let md = "Many attempts cost around **$1**, so retries are cheap. [${OAK-SOURCE}](oak:35)"
        XCTAssertEqual(spans(md), [])
    }

    func testEmphasisCharactersInsideMathStayLaTeX() {
        XCTAssertEqual(spans(#"Let $a_1 * b_2 * c_3$ be"#).map(\.latex), [#"a_1 * b_2 * c_3"#])
        XCTAssertEqual(spans(#"$x_i$ and $y_i$"#).map(\.latex), ["x_i", "y_i"])
    }

    func testBackslashesInsideMathAreKept() {
        XCTAssertEqual(spans(#"rows $a \\ b$ end"#).map(\.latex), [#"a \\ b"#])
        XCTAssertEqual(spans(#"set $\{1, 2\}$"#).map(\.latex), [#"\{1, 2\}"#])
    }

    func testCmarkNeverSeesTheFormula() {
        // Before the swap, cmark read `_1 * b_` as emphasis and the formula failed.
        let text = MarkdownAttributedBuilder.attributedString(for: #"Let $a_1 * b_2$ hold"#, theme: .chatGPT)
        XCTAssertEqual(attachmentCount(text), 1)
        XCTAssertFalse(text.string.contains("a_1"))
        XCTAssertFalse(text.string.contains("\u{E000}"))
    }

    func testDollarsInCodeSpansAreUntouched() {
        XCTAssertEqual(spans("Run `echo $x$` now"), [])
        XCTAssertEqual(spans("Run ``a ` $x$`` now"), [])
        let text = MarkdownAttributedBuilder.attributedString(for: "Run `echo $HOME$` now", theme: .chatGPT)
        XCTAssertTrue(text.string.contains("echo $HOME$"))
    }

    func testUnclosedBacktickIsLiteralAndMathStillFound() {
        XCTAssertEqual(spans("a ` stray and $x$").map(\.latex), ["x"])
    }

    func testFencedCodeIsUntouched() {
        let markdown = "```sh\necho $a$ $b$\n```\nthen $c$"
        let (text, found) = MathPlaceholders.protect(markdown)
        XCTAssertEqual(found.map(\.latex), ["c"])
        XCTAssertTrue(text.hasPrefix("```sh\necho $a$ $b$\n```\n"))
    }

    func testCurrencyIsNotMath() {
        XCTAssertEqual(spans("costs $5 and $10 today"), [])
        XCTAssertEqual(spans("price $ 5$"), [])
        XCTAssertEqual(spans(#"escaped \$x\$ stays"#), [])
    }

    func testCitationPlaceholdersAreNotMath() {
        XCTAssertEqual(spans("One [${OAK-SOURCE}](oak:1). Two [${OAK-SOURCE}](oak:8)."), [])
    }

    func testInlineMathStaysOnOneLine() {
        XCTAssertEqual(spans("a $x\ny$ b"), [])
    }

    func testDisplaySpanInsideProse() {
        let found = spans("so $$x^2$$ holds")
        XCTAssertEqual(found, [MathSpan(latex: "x^2", display: true, source: "$$x^2$$")])
    }

    func testUnclosedDisplayStaysText() {
        XCTAssertEqual(spans("streaming $$x = "), [])
    }

    func testPiecesRoundTrip() {
        let markdown = #"a $x$ b `$y$` c $$z$$"#
        let (text, found) = MathPlaceholders.protect(markdown)
        XCTAssertEqual(MathPlaceholders.restoreSource(text, spans: found), markdown)
        XCTAssertEqual(MathPlaceholders.pieces(in: text, spans: found).count, 4)
    }

    func testPipeInsideMathDoesNotSplitTableCell() {
        let source = "| a | b |\n|---|---|\n| $|x|$ | 2 |"
        let parsed = TableParser.parse(source: source, theme: .chatGPT)
        XCTAssertEqual(parsed.columnCount, 2)
        XCTAssertEqual(parsed.rows.count, 2)
        XCTAssertEqual(parsed.rows[1][1].string, "2")
        XCTAssertEqual(attachmentCount(parsed.rows[1][0]), 1)
    }

    func testMathInsideStrongAndLinkText() {
        let text = MarkdownAttributedBuilder.attributedString(for: "**是 $x^2$** and [see $y$](https://a.b)", theme: .chatGPT)
        XCTAssertEqual(attachmentCount(text), 2)
    }
}
