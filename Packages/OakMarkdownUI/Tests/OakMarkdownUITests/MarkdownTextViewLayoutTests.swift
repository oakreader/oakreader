import XCTest
import AppKit
@testable import OakMarkdownUI

/// Regression tests for the chat-panel horizontal-overflow / clipping bug
/// (see HANDOFF-chat-overflow.md). The wrap width of a prose block is the text
/// container's width; the bug was that a SwiftUI `sizeThatFits` probe *wider* than
/// the committed frame could fire last, leaving the container wider than the view so
/// long lines wrapped past the frame and clipped at the panel edge.
///
/// These tests don't need a window or synthetic keyboard input (both blocked under
/// Secure Input in CI) — they drive the AppKit layout path directly.
final class MarkdownTextViewLayoutTests: XCTestCase {

    /// Build a `MarkdownTextView` wired exactly like `ProseBlockView.makeNSView`.
    private func makeTextView(text: String, frameWidth: CGFloat) -> (MarkdownTextView, NSTextContainer) {
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        let layoutManager = HuggingLayoutManager()
        storage.addLayoutManager(layoutManager)
        let bigHeight = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: CGSize(width: 0, height: bigHeight))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let tv = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: frameWidth, height: 400),
                                  textContainer: container)
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize.zero
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        container.widthTracksTextView = false
        return (tv, container)
    }

    /// THE bug: a stale, over-wide container width (left by a late `sizeThatFits`
    /// probe) must be corrected to the committed frame width on the next layout pass.
    func testLayoutPinsContainerWidthToCommittedFrame() {
        let (tv, container) = makeTextView(
            text: "This is a long single line about Agent Verification that must wrap",
            frameWidth: 553.5)

        // Simulate the over-wide probe (692.296 in the captured instrumentation)
        // landing last and leaving the container wider than the view.
        container.size = NSSize(width: 692.296, height: CGFloat.greatestFiniteMagnitude)
        XCTAssertEqual(container.size.width, 692.296, accuracy: 0.01,
                       "precondition: container starts in the buggy too-wide state")

        tv.layout()

        XCTAssertEqual(container.size.width, 553.5, accuracy: 0.5,
                       "layout() must pin the wrap width to the committed frame so text " +
                       "wraps within the drawn bounds instead of clipping at the edge")
    }

    /// Idempotence / no feedback loop: once synced, a second layout pass is a no-op
    /// (the `abs(...) > 0.5` guard prevents re-setting and any resulting churn).
    func testRepeatedLayoutIsStable() {
        let (tv, container) = makeTextView(text: "Stable", frameWidth: 480)
        container.size = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        tv.layout()
        let afterFirst = container.size.width
        tv.layout()
        tv.layout()
        XCTAssertEqual(container.size.width, afterFirst, accuracy: 0.001,
                       "wrap width must converge and stay put across layout passes")
        XCTAssertEqual(afterFirst, 480, accuracy: 0.5)
    }

    /// A genuinely long line must occupy multiple line fragments at the narrow width —
    /// i.e. it actually wraps rather than overflowing as one clipped line.
    func testLongLineWrapsAtNarrowWidth() {
        let long = String(repeating: "wrapme ", count: 60)
        let (tv, container) = makeTextView(text: long, frameWidth: 300)
        tv.layout()
        guard let lm = tv.layoutManager else { return XCTFail("no layout manager") }
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)
        XCTAssertLessThanOrEqual(used.width, 300 + 0.5,
                                 "wrapped text must not exceed the container width")
        // Single 13pt line is ~16pt tall; 60 repeats at 300pt must be many lines.
        XCTAssertGreaterThan(used.height, 40,
                             "long text must wrap onto multiple lines at a narrow width")
    }
}
