import XCTest
import AppKit
@testable import OakMarkdownUI

/// Regression tests for the chat-panel horizontal-overflow bug: a long line
/// wrapping past the frame and clipping at the panel edge.
///
/// A prose block wraps at its text container's width. The bug was that
/// `sizeThatFits` measured through the *display* container, so a probe wider
/// than the committed frame could fire last and leave the wrap width too wide —
/// most visibly the moment a streamed answer settled, when nothing re-pinned it.
///
/// The fix was structural rather than corrective: measurement moved to a second,
/// never-drawn container, and the display container's width is governed solely
/// by `widthTracksTextView`. So what these pin is that separation — a probe
/// cannot reach the rendered width — rather than the old override that used to
/// put the width back afterwards.
///
/// No window or synthetic input needed; they drive the AppKit layout path directly.
final class MarkdownTextViewLayoutTests: XCTestCase {

    /// Wired exactly like `ProseBlockView.makeNSView`, in its order — including
    /// that `widthTracksTextView` is set AFTER `isHorizontallyResizable`, whose
    /// setter can switch tracking off, and that the frame arrives afterwards.
    /// The last part matters: tracking syncs the container when the view is
    /// *resized*, so a view born at its final size never syncs at all. SwiftUI
    /// sizes the view after `makeNSView` returns, which is what makes it work
    /// there — and what a test has to reproduce rather than assume.
    private func makeTextView(text: String, frameWidth: CGFloat) -> (MarkdownTextView, NSTextContainer) {
        let storage = NSTextStorage(attributedString: NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        let layoutManager = HuggingLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let tv = MarkdownTextView(frame: .zero, textContainer: container)
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize.zero
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        container.widthTracksTextView = true

        tv.setFrameSize(NSSize(width: frameWidth, height: 400))
        return (tv, container)
    }

    /// The wrap width is the committed frame's, with nothing having to put it there.
    func testWrapWidthFollowsTheCommittedFrame() {
        let (tv, container) = makeTextView(
            text: "A long single line about Agent Verification that must wrap",
            frameWidth: 553.5)

        tv.layout()

        XCTAssertEqual(container.size.width, 553.5, accuracy: 0.5,
                       "text must wrap within the drawn bounds rather than clipping at the edge")
    }

    /// THE bug, stated as the property that now prevents it: measuring a height
    /// at some other width must not touch the width the view draws at. This is
    /// what the second container buys, and it fails on any design where the
    /// probe and the display share one.
    func testMeasuringDoesNotDisturbTheDisplayWidth() {
        let (tv, container) = makeTextView(text: "Measured, not re-wrapped", frameWidth: 400)
        tv.layout()
        let drawn = container.size.width

        // The over-wide probe from the captured instrumentation.
        _ = tv.measuredHeight(forWidth: 692.296)

        XCTAssertEqual(container.size.width, drawn, accuracy: 0.001,
                       "a measurement probe must not become the rendered wrap width")
    }

    /// Measuring still answers about the width it was asked about — otherwise the
    /// test above would pass on a measurement that does nothing.
    func testMeasuringIsNarrowerWhenTheWidthIs() {
        let (tv, _) = makeTextView(text: String(repeating: "wrapme ", count: 60), frameWidth: 400)
        let wide = tv.measuredHeight(forWidth: 600)
        let narrow = tv.measuredHeight(forWidth: 200)
        XCTAssertGreaterThan(narrow, wide, "narrower text needs more lines, so more height")
    }

    /// Layout converges: a second pass changes nothing.
    func testRepeatedLayoutIsStable() {
        let (tv, container) = makeTextView(text: "Stable", frameWidth: 480)
        tv.layout()
        let afterFirst = container.size.width
        tv.layout()
        tv.layout()
        XCTAssertEqual(container.size.width, afterFirst, accuracy: 0.001,
                       "wrap width must converge and stay put across layout passes")
        XCTAssertEqual(afterFirst, 480, accuracy: 0.5)
    }

    /// A genuinely long line occupies several line fragments at a narrow width —
    /// it wraps rather than overflowing as one clipped line.
    func testLongLineWrapsAtNarrowWidth() {
        let (tv, container) = makeTextView(
            text: String(repeating: "wrapme ", count: 60), frameWidth: 300)
        tv.layout()
        guard let lm = tv.layoutManager else { return XCTFail("no layout manager") }
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)

        XCTAssertLessThanOrEqual(used.width, 300 + 0.5,
                                 "wrapped text must not exceed the container width")
        // A single 13pt line is ~16pt tall; 60 repeats at 300pt must be many.
        XCTAssertGreaterThan(used.height, 40,
                             "long text must wrap onto multiple lines at a narrow width")
    }
}
