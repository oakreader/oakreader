import XCTest
@testable import OakMarkdownUI

/// The streaming trailing block optimistically closes a half-arrived link so a citation
/// shows its label instead of flashing the raw `oak://cite/…` URL mid-stream.
final class StreamingMarkdownSanitizerTests: XCTestCase {

    func testClosesDanglingCitationLink() {
        let mid = "As the paper notes [based solely on attention](oak://cite/vaswani2017?page=2&text=based"
        XCTAssertEqual(StreamingMarkdownSanitizer.completeTrailingLink(mid), mid + ")")
    }

    func testLeavesClosedLinkUntouched() {
        let done = "see [p. 2](oak://cite/vaswani2017?page=2) for details"
        XCTAssertEqual(StreamingMarkdownSanitizer.completeTrailingLink(done), done)
    }

    func testNoLinkIsUnchanged() {
        let prose = "Just some streaming prose with no link yet"
        XCTAssertEqual(StreamingMarkdownSanitizer.completeTrailingLink(prose), prose)
    }

    func testIgnoresFragmentWithSpace() {
        // A space after `](` can't be a bare citation URL — leave it alone.
        let titled = "[label](some url with spaces"
        XCTAssertEqual(StreamingMarkdownSanitizer.completeTrailingLink(titled), titled)
    }

    func testIgnoresFragmentSpanningNewline() {
        let multiline = "[label](oak://cite/key\nnext line"
        XCTAssertEqual(StreamingMarkdownSanitizer.completeTrailingLink(multiline), multiline)
    }

    func testEmptyUrlFragmentIsUnchanged() {
        // `](` with nothing after it yet — wait for the URL before closing.
        let bare = "the label is [here]("
        XCTAssertEqual(StreamingMarkdownSanitizer.completeTrailingLink(bare), bare)
    }
}
