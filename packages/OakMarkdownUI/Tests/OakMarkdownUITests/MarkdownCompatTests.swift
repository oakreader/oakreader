import XCTest
@testable import OakMarkdownUI

/// CJK text puts no space around `**`, which CommonMark's flanking rules need, and
/// models write LaTeX commands SwiftUIMath does not know.
@MainActor
final class MarkdownCompatTests: XCTestCase {

    private func boldRuns(_ markdown: String) -> [String] {
        let text = MarkdownAttributedBuilder.attributedString(for: markdown, theme: .chatGPT)
        var runs: [String] = []
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            // Strong renders at .medium, not the .bold trait — read the weight itself.
            let traits = (value as? NSFont)?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
            if let weight = traits?[.weight] as? CGFloat, weight > NSFont.Weight.regular.rawValue {
                runs.append((text.string as NSString).substring(with: range))
            }
        }
        return runs
    }

    func testCloserAfterFullwidthPunctuation() {
        XCTAssertEqual(boldRuns("**学习方式：**每读完一个定义"), ["学习方式："])
    }

    func testOpenerBeforeFullwidthPunctuation() {
        XCTAssertEqual(boldRuns("我们说**「迹」**是对角线之和"), ["「迹」"])
    }

    func testShimsNeverReachTheText() {
        let text = MarkdownAttributedBuilder.attributedString(for: "**学习方式：**每", theme: .chatGPT)
        XCTAssertFalse(text.string.contains(MarkdownCompat.shim))
        XCTAssertEqual(text.string, "学习方式：每")
    }

    func testEnglishEmphasisUnchanged() {
        XCTAssertEqual(MarkdownCompat.shimCJKEmphasis("a **b**, c"), "a **b**, c")
        XCTAssertEqual(boldRuns("Use **this**, not that."), ["this"])
    }

    func testOperatornameBecomesMathrm() {
        XCTAssertEqual(MarkdownCompat.normalizeLaTeX(#"\operatorname{tr}(A)"#), #"\mathrm{tr}(A)"#)
        XCTAssertEqual(MarkdownCompat.normalizeLaTeX(#"\operatorname*{arg max}"#), #"\mathrm{arg max}"#)
    }

    func testOperatornameRendersAsMath() {
        let text = MarkdownAttributedBuilder.attributedString(for: #"迹 $\operatorname{tr}(A)$：和"#, theme: .chatGPT)
        XCTAssertFalse(text.string.contains("operatorname"))
        XCTAssertTrue(text.containsAttachments(in: NSRange(location: 0, length: text.length)))
    }
}
