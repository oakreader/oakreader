import XCTest
@testable import OakMarkdownUI

/// Display math renders only when `$$…$$` is a block on its own. Models often
/// glue it to prose or put blank lines inside it; the splitter isolates it.
final class MarkdownMathSplitterTests: XCTestCase {

    func testProseOnSameLineAsOpeningDelimiterIsSplitOff() {
        let markdown = #"""
        如$$
        \left[\begin{array}{cc|c}
        1&2&0\\
        2&4&0
        \end{array}\right].
        $$
        最后一列代表常数。
        """#
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertEqual(blocks.map(\.kind), [.prose, .mathDisplay, .prose])
        XCTAssertEqual(blocks[0].text, "如")
        XCTAssertTrue(blocks[1].text.contains(#"1&2&0\\"#))
        XCTAssertTrue(blocks[1].text.contains(#"\end{array}"#))
    }

    func testBlankLinesInsideDisplayMathDoNotSplitIt() {
        let markdown = "$$\na = b\n\nc = d\n$$"
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, .mathDisplay)
    }

    func testDisplayMathInsideSentenceBecomesOwnBlock() {
        let blocks = MarkdownBlockSplitter.split("所以 $$x^2 = 4$$ 成立。")
        XCTAssertEqual(blocks.map(\.kind), [.prose, .mathDisplay, .prose])
        XCTAssertEqual(MathDelimiters.stripDisplay(blocks[1].text), "x^2 = 4")
    }

    func testBracketDelimitersAreDisplayMath() {
        let blocks = MarkdownBlockSplitter.split("Text\n\\[\nx + y\n\\]\nMore")
        XCTAssertEqual(blocks.map(\.kind), [.prose, .mathDisplay, .prose])
    }

    func testParenDelimitersBecomeInlineMath() {
        let blocks = MarkdownBlockSplitter.split(#"where \(c \times 0 = 0\) holds"#)
        XCTAssertEqual(blocks.first?.text, "where $c \\times 0 = 0$ holds")
    }

    func testEscapedBracketMidSentenceIsUntouched() {
        let blocks = MarkdownBlockSplitter.split(#"see \[1\] for details"#)
        XCTAssertEqual(blocks.first?.text, #"see \[1\] for details"#)
    }

    func testDollarsInsideCodeFenceAreUntouched() {
        let markdown = "```sh\necho $$\n```"
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.text, markdown)
    }

    func testUnclosedMathWhileStreamingStaysOpen() {
        let blocks = MarkdownBlockSplitter.split("如$$\nx = 1")
        XCTAssertEqual(blocks.map(\.kind), [.prose, .mathDisplayOpen])
        XCTAssertEqual(blocks.last?.text, "$$\nx = 1")
        XCTAssertFalse(blocks.last!.isSettled)
    }

    func testDollarsInsideInlineCodeAreUntouched() {
        let markdown = "Run `echo $$` to print the PID.\n\nNext paragraph."
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertEqual(blocks.map(\.text), ["Run `echo $$` to print the PID.", "Next paragraph."])
    }

    func testStrayDelimiterKeepsLaterParagraphsApart() {
        let markdown = "It costs $$ here.\n\nSecond paragraph.\n\nThird paragraph."
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertEqual(blocks.map(\.text), ["It costs ", "$$ here.", "Second paragraph.", "Third paragraph."])
    }

    func testLatexLineBreakBeforeParenIsNotADelimiter() {
        let markdown = #"$$\begin{pmatrix} a \\(b) & c \end{pmatrix}$$"#
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertEqual(blocks.first?.kind, .mathDisplay)
        XCTAssertTrue(blocks.first!.text.contains(#"\\(b)"#))
    }
}
