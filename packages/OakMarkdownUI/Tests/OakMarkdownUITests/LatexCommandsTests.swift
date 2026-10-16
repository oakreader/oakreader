import XCTest
@testable import OakMarkdownUI

/// The commands ChatGPT patches into iosMath draw natively here too, so they never
/// wait on the KaTeX fallback.
@MainActor
final class LatexCommandsTests: XCTestCase {

    func testRewrites() {
        XCTAssertEqual(LatexCommands.rewrite(#"a,\dots,b"#), #"a,\ldots,b"#)
        XCTAssertEqual(LatexCommands.rewrite(#"\dots x"#), #"\ldots x"#)
        XCTAssertEqual(LatexCommands.rewrite(#"\lvert x \rvert"#), "| x |")
        XCTAssertEqual(LatexCommands.rewrite(#"\bigl( x \bigr)"#), "( x )")
        XCTAssertEqual(LatexCommands.rewrite(#"\operatorname*{arg max}"#), #"\mathrm{arg max}"#)
        XCTAssertEqual(LatexCommands.rewrite(#"\operatorname {tr}"#), #"\mathrm {tr}"#)
    }

    func testKnownCommandsAndPrefixesAreLeftAlone() {
        XCTAssertEqual(LatexCommands.rewrite(#"\ldots \bigcup \vdots \lvertneqq"#), #"\ldots \bigcup \vdots \lvertneqq"#)
        XCTAssertEqual(LatexCommands.rewrite(#"a \\ b"#), #"a \\ b"#)
    }

    func testChatGPTTableDrawsNatively() {
        let formulas = [#"\bigl( x \bigr)"#, #"\Bigl[ x \Bigr]"#, #"\biggl\{ x \biggr\}"#, #"a,\dots,b"#,
                        #"\lvert x \rvert"#, #"\lVert x \rVert"#, #"\operatorname{tr}(A)"#, #"\Gamma \vdash e"#,
                        #"A \leftrightharpoons B"#, #"x \coloneqq 1"#, #"p \implies q"#, #"\iiint f"#]
        for f in formulas {
            XCTAssertTrue(MathRoute.nativeCanDraw(f, display: false, fontSize: 14), f)
        }
    }

    func testNonLatinTextGoesToKaTeX() {
        XCTAssertTrue(MathRoute.hasNonLatinText(#"\text{скорость}"#))
        XCTAssertTrue(MathRoute.hasNonLatinText(#"\text{速度}"#))
        XCTAssertTrue(MathRoute.hasNonLatinText("x：y"))
        XCTAssertFalse(MathRoute.hasNonLatinText(#"α + β \in ℝ"#))
        XCTAssertFalse(MathRoute.hasNonLatinText("é + ü"))
    }

    func testStatsReportEachFormulaAndUnknownCommandOnce() {
        var events: [String] = []
        MathRenderStats.sink = { name, props in events.append("\(name):\(props["renderer"] ?? props["command"] ?? "")") }
        defer { MathRenderStats.sink = nil }
        _ = MathRoute.nativeCanDraw(#"\frac{1}{77}"#, display: false, fontSize: 14)
        _ = MathRoute.nativeCanDraw(#"\frac{1}{77}"#, display: false, fontSize: 14)
        _ = MathRoute.nativeCanDraw(#"\boxed{77}"#, display: false, fontSize: 14)
        _ = MathRoute.nativeCanDraw(#"\boxed{78}"#, display: false, fontSize: 14)
        XCTAssertEqual(events, ["latex_render:native", "latex_unknown_command:boxed"])
    }
}
