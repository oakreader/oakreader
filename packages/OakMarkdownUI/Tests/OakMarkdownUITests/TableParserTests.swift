import XCTest
@testable import OakMarkdownUI

/// cmark-gfm names the header row `table_header`, not a `table_row` carrying an
/// is-header flag. The parser must walk both, or the header row is silently dropped
/// (the bug where a table rendered its data rows but no header).
final class TableParserTests: XCTestCase {

    @MainActor
    func testHeaderRowIsCapturedAndFlagged() {
        let md = """
        | 主题 | 讨论 |
        |---|---|
        | GLM-5.2 的整体水平 | 很多人认为是一次跃升 |
        | 成本与速度 | 取决于场景 |
        """
        let parsed = TableParser.parse(source: md, theme: .oak())
        XCTAssertTrue(parsed.hasHeader, "header row must be detected")
        XCTAssertEqual(parsed.rows.count, 3, "header + two data rows")
        XCTAssertEqual(parsed.rows.first?.map(\.string), ["主题", "讨论"])
        XCTAssertEqual(parsed.rows.last?.map(\.string), ["成本与速度", "取决于场景"])
    }

    @MainActor
    func testColumnAndAlignmentCount() {
        let md = """
        | L | C | R |
        | :--- | :---: | ---: |
        | a | b | c |
        """
        let parsed = TableParser.parse(source: md, theme: .oak())
        XCTAssertEqual(parsed.columnCount, 3)
        XCTAssertEqual(parsed.alignment(forColumn: 0), .leading)
        XCTAssertEqual(parsed.alignment(forColumn: 1), .center)
        XCTAssertEqual(parsed.alignment(forColumn: 2), .trailing)
    }
}
