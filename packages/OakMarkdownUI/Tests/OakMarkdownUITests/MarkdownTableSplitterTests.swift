import XCTest
@testable import OakMarkdownUI

/// The block splitter needs to detect GFM pipe tables so the renderer can route
/// them to a Grid-based view. The detection key is a header line containing `|`
/// followed by a separator line of dashes (with optional alignment colons).
final class MarkdownTableSplitterTests: XCTestCase {

    func testWellFormedTableIsClassifiedAsTable() {
        let markdown = """
        | Dimension | Weight space | Text space |
        |---|---|---|
        | element | reals | tokens |
        """
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, .table)
    }

    func testAlignmentColonsAreAccepted() {
        let markdown = """
        | Left | Center | Right |
        | :--- | :---: | ---: |
        | a | b | c |
        """
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertEqual(blocks.first?.kind, .table)
    }

    func testParagraphWithStrayPipeStaysProse() {
        let markdown = "f(x) = x | x > 0\nnext sentence."
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertEqual(blocks.first?.kind, .prose)
    }

    func testNonSeparatorSecondLineStaysProse() {
        // Looks table-ish but the second line isn't a dashes separator.
        let markdown = """
        | foo | bar |
        | not | a separator |
        """
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertEqual(blocks.first?.kind, .prose)
    }

    func testBlankLineBetweenRowsSplitsIntoMultipleBlocks() {
        // GFM spec: a blank line ends the table. We honor that — the renderer
        // can't recover this shape without a tolerance pass, which lives in a
        // separate (prompt-side) fix.
        let markdown = """
        | Dimension | Weight space |

        |---|---|

        | element | reals |
        """
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertGreaterThan(blocks.count, 1)
        // First block is just two lines — header + nothing — so it should NOT
        // be classified as a table (no separator line follows in the same block).
        XCTAssertNotEqual(blocks.first?.kind, .table)
    }

    func testCodeFenceWithPipesStaysCode() {
        let markdown = """
        ```
        | not | a | table |
        |---|---|---|
        ```
        """
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertEqual(blocks.count, 1)
        if case .code = blocks.first?.kind {
            // expected
        } else {
            XCTFail("Code fence should not be classified as a table")
        }
    }
}
