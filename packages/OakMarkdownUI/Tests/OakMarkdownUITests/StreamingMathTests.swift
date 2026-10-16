import XCTest
@testable import OakMarkdownUI

@MainActor
final class StreamingMathTests: XCTestCase {
    private let reply = "解为\n\n$$\nx=\\frac{-b\\pm\\sqrt{b^2-4ac}}{2a}\n$$\n\n完"

    /// Every prefix that ends inside the span is an open formula, never prose.
    func testUnclosedSpanIsOpenFormulaWhileStreaming() {
        let open = reply.range(of: "$$")!.upperBound
        let close = reply.range(of: "$$", range: open..<reply.endIndex)!.lowerBound
        var end = reply.index(after: open)
        while end <= close {
            let last = MarkdownBlockSplitter.split(String(reply[..<end])).last!
            XCTAssertEqual(last.kind, .mathDisplayOpen, String(reply[..<end]).debugDescription)
            end = reply.index(after: end)
        }
        let closed = MarkdownBlockSplitter.split(String(reply[..<reply.index(close, offsetBy: 2)]))
        XCTAssertEqual(closed.last?.kind, .mathDisplay)
    }

    func testHalfArrivedCloseIsStripped() {
        XCTAssertEqual(MathDelimiters.stripOpenDisplay("$$\nx^2\n$"), "x^2")
        XCTAssertEqual(MathDelimiters.stripOpenDisplay("$$\na \\$"), "a \\$")
    }

    func testOpenGroupsAreClosedInnermostFirst() {
        XCTAssertEqual(StreamingMath.closingOpenGroups(#"\sqrt{b^2"#), #"\sqrt{b^2}"#)
        XCTAssertEqual(StreamingMath.closingOpenGroups(#"\left( \frac{a"#), #"\left( \frac{a}\right."#)
        XCTAssertEqual(StreamingMath.closingOpenGroups(#"\begin{aligned} a &= {b"#),
                       #"\begin{aligned} a &= {b}\end{aligned}"#)
        XCTAssertEqual(StreamingMath.closingOpenGroups(#"\{a\}"#), #"\{a\}"#)
    }

    /// Some prefix draws at every step after the first symbol, and the full formula
    /// draws unchanged.
    func testEveryPrefixDrawsSomething() {
        let latex = #"x=\frac{-b\pm\sqrt{b^2-4ac}}{2a}"#
        var end = latex.index(after: latex.startIndex)
        while end <= latex.endIndex {
            XCTAssertNotNil(StreamingMath.drawablePrefix(String(latex[..<end]), fontSize: 16),
                            String(latex[..<end]))
            if end == latex.endIndex { break }
            end = latex.index(after: end)
        }
        XCTAssertEqual(StreamingMath.drawablePrefix(latex, fontSize: 16), latex)
    }

    func testHalfTypedCommandIsDropped() {
        XCTAssertEqual(StreamingMath.drawablePrefix(#"a+\fra"#, fontSize: 16), "a+")
    }

    func testNonLatinWaitsForKatex() {
        XCTAssertNil(StreamingMath.drawablePrefix(#"v=\text{速度"#, fontSize: 16))
    }
}
