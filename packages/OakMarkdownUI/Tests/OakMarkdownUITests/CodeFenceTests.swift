import XCTest
@testable import OakMarkdownUI

/// A widget block shows a placeholder until its closing fence arrives, then the
/// widget. These pin where that line falls while a reply streams.
final class CodeFenceTests: XCTestCase {
    func testOpeningFenceAloneIsOpen() {
        XCTAssertFalse(CodeFence.isClosed("```genui"))
        XCTAssertFalse(CodeFence.isClosed("```genui\n{\"root\":"))
    }

    func testClosingFenceCloses() {
        XCTAssertTrue(CodeFence.isClosed("```genui\n{\"root\":{}}\n```"))
        XCTAssertTrue(CodeFence.isClosed("```genui\n{}\n```\n"))
    }

    func testWidgetFenceStaysOneBlockWhileStreaming() {
        let blocks = MarkdownBlockSplitter.split("Here:\n\n```genui\n{\"root\":\n\n{\"type\":\"text\"}")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.last?.kind, .code(language: "genui"))
    }
}
