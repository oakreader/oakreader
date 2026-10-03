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

    /// Models routinely put a blank line between every row. That is malformed
    /// GFM — a blank line ends a table — but it is unambiguously meant as one,
    /// and before this the rows rendered as prose with the pipes showing.
    func testTableWithBlankLinesBetweenRowsIsRejoined() {
        let markdown = """
        | 搭配 | 含义 |

        |------|------|

        | preliminary evidence | 初步证据 |

        | preliminary hearing | 预审听证 |
        """
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, .table)
    }

    /// The merge only survives if the result is really a table, so consecutive
    /// quote-like lines starting with a pipe are left as they were.
    func testPipePrefixedProseRunIsNotMergedIntoATable() {
        let markdown = """
        | not a header

        | still not a table
        """
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.first?.kind, .prose)
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

    /// Reversed 2026-10-03. This previously asserted the opposite: GFM says a
    /// blank line ends a table, so the splitter honoured that and the fix was
    /// left to the prompt side. It never held — models from several providers
    /// keep emitting blank-line-separated rows, and the rows rendered as prose
    /// with the pipes showing (seen in the Translation panel).
    ///
    /// A prompt cannot be relied on to never produce this; the renderer can be
    /// made to accept it once. The tolerance pass only survives when the merged
    /// run validates as a real table, so nothing else is reclassified — see
    /// `testPipePrefixedProseRunIsNotMergedIntoATable`.
    func testBlankLineBetweenRowsIsRecoveredAsOneTable() {
        let markdown = """
        | Dimension | Weight space |

        |---|---|

        | element | reals |
        """
        let blocks = MarkdownBlockSplitter.split(markdown)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, .table)
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
