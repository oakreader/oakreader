import XCTest
@testable import OakMarkdownUI

/// SwiftUIMath draws first. CJK and formulas it cannot parse go to KaTeX, whose
/// MathML WebKit draws.
@MainActor
final class MathFallbackTests: XCTestCase {

    func testRouteKeepsPlainFormulasNative() {
        XCTAssertTrue(MathRoute.nativeCanDraw(#"\frac{a}{b} + x^2"#, display: false, fontSize: 15))
        XCTAssertTrue(MathRoute.nativeCanDraw(#"\operatorname{tr}(A)"#, display: false, fontSize: 15))
    }

    func testRouteSendsCJKToKaTeX() {
        XCTAssertTrue(MathRoute.hasNonLatinText(#"v = \frac{\text{路程}}{\text{时间}}"#))
        XCTAssertFalse(MathRoute.nativeCanDraw(#"\text{速度} = v"#, display: false, fontSize: 15))
        XCTAssertFalse(MathRoute.hasNonLatinText(#"\alpha + \beta"#))
    }

    func testRouteSendsUnknownCommandsToKaTeX() {
        // SwiftUIMath has no `\xrightarrow`; KaTeX does.
        XCTAssertFalse(MathRoute.nativeCanDraw(#"A \xrightarrow{f} B"#, display: false, fontSize: 15))
        XCTAssertNotNil(KatexEngine.shared.mathML(for: #"A \xrightarrow{f} B"#, display: false))
    }

    func testKatexEmitsMathML() throws {
        let mathML = try XCTUnwrap(KatexEngine.shared.mathML(for: #"\text{速度} = \frac{s}{t}"#, display: false))
        XCTAssertTrue(mathML.contains("<math"))
        XCTAssertTrue(mathML.contains("速度"))
        XCTAssertFalse(mathML.contains("katex-html"), "MathML only, no HTML layer that would need KaTeX CSS")
        let display = try XCTUnwrap(KatexEngine.shared.mathML(for: "x", display: true))
        XCTAssertTrue(display.contains(#"display="block""#))
    }

    func testKatexRejectsBrokenInput() {
        XCTAssertNil(KatexEngine.shared.mathML(for: #"\frac{a"#, display: false))
    }

    func testBrokenFormulaShowsAsTyped() {
        let text = MarkdownAttributedBuilder.attributedString(for: #"bad $\frac{a$ here"#, theme: .chatGPT)
        XCTAssertEqual(text.string, #"bad $\frac{a$ here"#)
    }

    func testWebKitDrawsCJKFormula() async throws {
        let rendered = await MathMLRenderer.shared.render(
            latex: #"\text{速度} = \frac{s}{t}"#, display: false, fontSize: 15, color: .black)
        let image = try XCTUnwrap(rendered)
        XCTAssertGreaterThan(image.image.size.width, 20)
        XCTAssertGreaterThan(image.image.size.height, 10)
        XCTAssertGreaterThan(image.descent, 0, "a fraction hangs below the baseline")

        // Some ink, on a clear background.
        let bitmap = try XCTUnwrap(image.image.representations.first as? NSBitmapImageRep
            ?? image.image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        XCTAssertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1, 0, accuracy: 0.01)
        var inked = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2)
            where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                inked += 1
            }
        }
        XCTAssertGreaterThan(inked, 20)
    }

    func testProseUsesFallbackImageOnceRendered() async {
        let markdown = #"速度 $\text{速度}=v$ 是"#
        let first = MarkdownAttributedBuilder.attributedString(for: markdown, theme: .chatGPT)
        XCTAssertTrue(first.string.contains("$"), "pending: the source shows as typed")
        _ = await MathMLRenderer.shared.render(
            latex: #"\text{速度}=v"#, display: false,
            fontSize: MarkdownTheme.chatGPT.bodyFont.pointSize, color: MarkdownTheme.chatGPT.textColor)
        let second = MarkdownAttributedBuilder.attributedString(for: markdown, theme: .chatGPT)
        XCTAssertFalse(second.string.contains("$"))
        XCTAssertTrue(second.containsAttachments(in: NSRange(location: 0, length: second.length)))
    }
}
