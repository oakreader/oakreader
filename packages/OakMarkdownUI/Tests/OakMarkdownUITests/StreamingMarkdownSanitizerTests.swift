import XCTest
@testable import OakMarkdownUI

/// The streaming trailing block optimistically closes a half-arrived link so a citation
/// shows its label instead of flashing the bare `oak:14` destination.
final class StreamingMarkdownSanitizerTests: XCTestCase {

    func testClosesDanglingCitationLink() {
        let mid = "As the paper notes [based solely on attention](oak:14"
        XCTAssertEqual(StreamingMarkdownSanitizer.completeTrailingLink(mid), mid + ")")
    }

    /// The window is one or two characters wide now — the destination is `oak:` plus a
    /// number — but it still exists, and an unclosed link renders its destination raw.
    func testClosesPartialDestination() {
        let mid = "see [p. 2](oak:"
        XCTAssertEqual(StreamingMarkdownSanitizer.completeTrailingLink(mid), mid + ")")
    }

    func testLeavesClosedLinkUntouched() {
        let done = "see [p. 2](oak:14) for details"
        XCTAssertEqual(StreamingMarkdownSanitizer.completeTrailingLink(done), done)
    }

    func testNoLinkIsUnchanged() {
        let prose = "Just some streaming prose with no link yet"
        XCTAssertEqual(StreamingMarkdownSanitizer.completeTrailingLink(prose), prose)
    }

    func testIgnoresFragmentWithSpace() {
        // A space after `](` can't be a bare destination — leave it alone.
        let titled = "[label](some url with spaces"
        XCTAssertEqual(StreamingMarkdownSanitizer.completeTrailingLink(titled), titled)
    }

    func testIgnoresFragmentSpanningNewline() {
        let multiline = "[label](oak:14\nnext line"
        XCTAssertEqual(StreamingMarkdownSanitizer.completeTrailingLink(multiline), multiline)
    }

    func testEmptyUrlFragmentIsUnchanged() {
        // `](` with nothing after it yet — wait for the destination before closing.
        let bare = "the label is [here]("
        XCTAssertEqual(StreamingMarkdownSanitizer.completeTrailingLink(bare), bare)
    }

    func testIsIdempotent() {
        let mid = "[p. 2](oak:14"
        let once = StreamingMarkdownSanitizer.completeTrailingLink(mid)
        XCTAssertEqual(StreamingMarkdownSanitizer.completeTrailingLink(once), once)
    }
}
