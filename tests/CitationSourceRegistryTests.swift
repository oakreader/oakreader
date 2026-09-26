import XCTest

/// Covers the table behind `oak:N` citation links.
///
/// The point of the handle protocol is that the model can only ever name a passage the app
/// handed it, so these tests pin the three properties that guarantee it: a passage gets a
/// number, that number resolves back to the exact text and location, and the number does
/// not change when the same passage is shown again.
final class CitationSourceRegistryTests: XCTestCase {

    private var directory: URL!
    private var sessionId: UUID!
    private var registry: CitationSourceRegistry!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("citation-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionId = UUID()
        registry = CitationSourceRegistry(sessionId: sessionId, directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Numbering

    func testNumbersEachParagraphAndResolvesItBack() {
        let page = """
            An attention function can be described as mapping a query and a set of key-value \
            pairs to an output, where the query, keys, values, and output are all vectors.

            We call our particular attention "Scaled Dot-Product Attention". The input \
            consists of queries and keys of dimension d_k, and values of dimension d_v.
            """

        let numbered = registry.numbered(page, itemId: "ITEM-1", page: 2)

        XCTAssertTrue(numbered.hasPrefix("[1] "), "first passage must be numbered")
        XCTAssertTrue(numbered.contains("[2] "), "second paragraph gets its own number")

        let first = registry.source(for: 1)
        XCTAssertEqual(first?.itemId, "ITEM-1")
        XCTAssertEqual(first?.page, 2, "page index is stored 0-based, as passed")
        XCTAssertTrue(first?.text?.hasPrefix("An attention function") == true)
        XCTAssertEqual(registry.source(for: 2)?.text?.hasPrefix("We call our particular"), true)
    }

    /// A short line is page furniture, not a claim worth its own number — folding it into
    /// the passage before it keeps the numbers sparse enough for the model to read past.
    func testShortLinesFoldIntoThePrecedingPassage() {
        let page = """
            The Transformer follows this overall architecture using stacked self-attention \
            and point-wise, fully connected layers for both the encoder and decoder.

            3.2 Attention
            """
        let numbered = registry.numbered(page, itemId: "ITEM-1", page: 0)

        XCTAssertFalse(numbered.contains("[2]"), "a short trailing fragment gets no number of its own")
        XCTAssertEqual(registry.source(for: 1)?.text?.contains("3.2 Attention"), true)
    }

    /// An over-long paragraph would highlight as a page-sized blob, so it is cut at a
    /// sentence boundary.
    func testOverlongParagraphIsSplitAtSentenceBoundaries() {
        // Distinct sentences: identical ones would share a fingerprint and dedupe to a
        // single number, which is correct behaviour but would hide the split under test.
        let paragraph = (1...20)
            .map { "Sentence number \($0) exists purely to pad this paragraph past the split threshold. " }
            .joined()   // ~1700 chars

        _ = registry.numbered(paragraph, itemId: "ITEM-1", page: 0)

        XCTAssertNotNil(registry.source(for: 2), "an over-long paragraph yields more than one passage")
        for id in 1...2 {
            guard let text = registry.source(for: id)?.text else {
                return XCTFail("passage \(id) should exist")
            }
            XCTAssertLessThanOrEqual(text.count, 900, "each chunk stays near the cap")
            XCTAssertTrue(text.hasSuffix("."), "chunks are cut at a sentence boundary")
        }
    }

    func testHeadingLocatesTheFollowingPassageAndIsNotItselfCited() {
        let markdown = """
            ## Batch Endpoints

            Batch jobs are processed asynchronously, and the documentation guarantees \
            completion within 24 hours of submission.
            """
        let numbered = registry.numbered(markdown, itemId: "ITEM-2")

        XCTAssertTrue(numbered.contains("## Batch Endpoints"), "the heading survives verbatim")
        XCTAssertFalse(numbered.contains("[1] ## Batch"), "a heading is not itself a citable passage")
        XCTAssertEqual(registry.source(for: 1)?.heading, "Batch Endpoints")
        XCTAssertNil(registry.source(for: 1)?.page, "an unpaged document locates by heading")
    }

    /// Layout newlines from PDF and HTML extraction would stop the highlighters from
    /// matching the passage as one contiguous run.
    func testStoredPassageIsWhitespaceNormalized() {
        registry.register(.init(itemId: "ITEM-1", page: 0, time: nil, heading: nil,
                                text: CitationSourceRegistry.normalized("one\n  two   three")))
        XCTAssertEqual(registry.source(for: 1)?.text, "one two three")
    }

    // MARK: - Identity

    func testSamePassageKeepsItsNumberAcrossTurns() {
        let page = "A passage long enough to earn a number of its very own in the source table."
        let first = registry.numbered(page, itemId: "ITEM-1", page: 4)
        let second = registry.numbered(page, itemId: "ITEM-1", page: 4)

        XCTAssertEqual(first, second, "re-showing a page must not renumber it")
        XCTAssertNil(registry.source(for: 2), "and must not grow the table")
    }

    /// The same running header appears on every page, so text alone can't identify a
    /// passage — the location is part of its identity.
    func testSameTextOnDifferentPagesGetsDistinctNumbers() {
        let header = "Attention Is All You Need — Vaswani et al., 31st Conference on NIPS 2017."
        _ = registry.numbered(header, itemId: "ITEM-1", page: 1)
        _ = registry.numbered(header, itemId: "ITEM-1", page: 2)

        XCTAssertEqual(registry.source(for: 1)?.page, 1)
        XCTAssertEqual(registry.source(for: 2)?.page, 2)
    }

    func testWholeDocumentHandleCarriesNoPassage() {
        let id = registry.register(.init(itemId: "ITEM-9", page: nil, time: nil,
                                         heading: nil, text: nil))
        XCTAssertNil(registry.source(for: id)?.text)
        XCTAssertEqual(registry.source(for: id)?.itemId, "ITEM-9")
    }

    func testUnknownNumberResolvesToNothing() {
        XCTAssertNil(registry.source(for: 999), "a number the model invented must not resolve")
    }

    // MARK: - Session lifecycle

    func testTableSurvivesReopeningTheConversation() {
        _ = registry.numbered("A passage that has to still be resolvable tomorrow morning.",
                              itemId: "ITEM-1", page: 3)
        registry.save()

        let reopened = CitationSourceRegistry(sessionId: sessionId, directory: directory)
        XCTAssertEqual(reopened.source(for: 1)?.text, registry.source(for: 1)?.text)
        XCTAssertEqual(reopened.source(for: 1)?.page, 3)
    }

    /// Numbers are per-conversation. Switching sessions must not let one chat's `oak:1`
    /// resolve to another chat's passage.
    func testSwitchingSessionsSwapsTheTable() {
        _ = registry.numbered("A passage belonging to the first conversation only.",
                              itemId: "ITEM-1", page: 0)
        registry.save()

        registry.activate(sessionId: UUID())
        XCTAssertNil(registry.source(for: 1), "a fresh conversation starts with an empty table")

        registry.activate(sessionId: sessionId)
        XCTAssertEqual(registry.source(for: 1)?.itemId, "ITEM-1", "the original table comes back")
    }

    func testNumbersContinueAfterReloadRatherThanRestarting() {
        _ = registry.numbered("The first passage of the conversation, long enough to count.",
                              itemId: "ITEM-1", page: 0)
        registry.save()

        let reopened = CitationSourceRegistry(sessionId: sessionId, directory: directory)
        let next = reopened.register(.init(itemId: "ITEM-2", page: nil, time: nil,
                                           heading: nil, text: nil))
        XCTAssertEqual(next, 2, "a reopened conversation must not reissue number 1")
    }

    func testDeletingAConversationRemovesItsTable() {
        _ = registry.numbered("A passage that should not outlive its conversation at all.",
                              itemId: "ITEM-1", page: 0)
        registry.save()

        CitationSourceRegistry.deleteTable(sessionId: sessionId, directory: directory)

        let reopened = CitationSourceRegistry(sessionId: sessionId, directory: directory)
        XCTAssertNil(reopened.source(for: 1))
    }
}
