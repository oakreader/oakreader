import XCTest
import AppKit
@testable import OakMarkdownUI

/// The streaming reveal hides appended text and lets a moving front fade it in.
/// What these pin is the one property a reader would notice if it broke: every
/// character ends at full opacity, whatever the stream did on the way.
///
/// The reveal runs on the window's display link, which stops while the screen
/// is locked. The tests replace its clock and call the frame tick themselves,
/// so they pass on a locked machine and in CI.
@MainActor
final class MarkdownTextViewRevealTests: XCTestCase {

    private var window: NSWindow?
    private var now: CFTimeInterval = 1000

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    private func makeTextView() -> MarkdownTextView {
        let storage = NSTextStorage()
        let layoutManager = HuggingLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let tv = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 400), textContainer: container)
        tv.isEditable = false
        tv.revealClock = { [unowned self] in self.now }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tv
        window.orderFrontRegardless()
        self.window = window
        return tv
    }

    private func append(_ text: String, to tv: MarkdownTextView) {
        guard let storage = tv.textStorage else { return XCTFail("no storage") }
        let start = storage.length
        storage.append(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        tv.fadeInAppendedText(NSRange(location: start, length: storage.length - start))
    }

    /// Characters still carrying a fade overlay.
    private func dimmedLength(_ tv: MarkdownTextView) -> Int {
        guard let lm = tv.layoutManager, let storage = tv.textStorage else { return 0 }
        var dimmed = 0
        var index = 0
        while index < storage.length {
            var effective = NSRange()
            let value = lm.temporaryAttribute(.foregroundColor, atCharacterIndex: index,
                                              effectiveRange: &effective)
            if value != nil { dimmed += effective.length }
            index = max(effective.upperBound, index + 1)
        }
        return dimmed
    }

    /// Advance the clock by `seconds` in 60 Hz frames, ticking the reveal each frame.
    private func spin(_ seconds: TimeInterval, _ tv: MarkdownTextView) {
        for _ in 0..<Int(seconds * 60) {
            now += 1.0 / 60.0
            tv.tickReveal()
        }
    }

    func testAppendedTextIsHiddenThenFullyRevealed() {
        let tv = makeTextView()
        tv.fadesAppendedText = true
        append("The answer streams in one slice at a time. ", to: tv)
        XCTAssertGreaterThan(dimmedLength(tv), 0, "appended text should start hidden")

        append("A second delta arrives while the first is still fading.", to: tv)
        spin(1.5, tv)
        XCTAssertEqual(dimmedLength(tv), 0, "every character should end at full opacity")
    }

    func testStreamEndDrainsTheBacklog() {
        let tv = makeTextView()
        tv.fadesAppendedText = true
        append(String(repeating: "word ", count: 400), to: tv)
        tv.fadesAppendedText = false
        spin(1.0, tv)
        XCTAssertEqual(dimmedLength(tv), 0, "a backlog left at stream end should drain")
    }

    func testRewriteBeforeTheFrontLeavesNothingDim() {
        let tv = makeTextView()
        tv.fadesAppendedText = true
        append(String(repeating: "word ", count: 200), to: tv)
        // A markdown reflow rewrote text up to here; nothing before it may stay hidden.
        tv.finalizeFades(before: 600)
        guard let lm = tv.layoutManager else { return XCTFail("no layout manager") }
        for index in stride(from: 0, to: 600, by: 37) {
            XCTAssertNil(lm.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil),
                         "character \(index) is before the rewrite point and must be visible")
        }
        spin(1.5, tv)
        XCTAssertEqual(dimmedLength(tv), 0)
    }

    func testLeavingTheWindowSettlesAtFullOpacity() {
        let tv = makeTextView()
        tv.fadesAppendedText = true
        append("Text that is still fading when its view is removed.", to: tv)
        tv.removeFromSuperview()
        XCTAssertEqual(dimmedLength(tv), 0)
    }
}
