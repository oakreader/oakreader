import AppKit
import XCTest
@testable import OakMarkdownUI

/// A citation's visible text is the host's to supply, not the model's. These
/// pin what the substitution does and — more importantly — what it refuses to
/// touch, since a resolver that fired on the wrong run would rewrite prose.
@MainActor
final class CitationLabelTests: XCTestCase {

    private func theme(resolving label: String? = nil) -> MarkdownTheme {
        var theme = MarkdownTheme.oak()
        if let label { theme.citationLabel = { _ in label } }
        return theme
    }

    private func render(_ markdown: String, _ theme: MarkdownTheme) -> NSAttributedString {
        MarkdownAttributedBuilder.attributedString(for: markdown, theme: theme)
    }

    func testPlaceholderBecomesTheResolvedLocation() {
        let out = render("Runs on a Mac [${OAK-SOURCE}](oak:14).", theme(resolving: "Page 15"))
        XCTAssertEqual(out.string, "Runs on a Mac Page 15.")
    }

    func testPlaceholderSurvivesAsALink() {
        let out = render("Runs on a Mac [${OAK-SOURCE}](oak:14).", theme(resolving: "Page 15"))
        let link = out.attribute(.link, at: out.string.count - 8, effectiveRange: nil) as? URL
        XCTAssertEqual(link?.absoluteString, "oak:14")
    }

    /// Without a host resolver the placeholder is left alone rather than
    /// silently deleted: a citation that cannot resolve should look wrong.
    func testUnresolvedPlaceholderIsLeftVisible() {
        let out = render("Runs on a Mac [${OAK-SOURCE}](oak:14).", theme())
        XCTAssertEqual(out.string, "Runs on a Mac ${OAK-SOURCE}.")
    }

    /// A resolver that returns nothing for this handle is the same case.
    func testResolverReturningNilLeavesThePlaceholder() {
        var t = MarkdownTheme.oak()
        t.citationLabel = { _ in nil }
        XCTAssertEqual(render("See [${OAK-SOURCE}](oak:9).", t).string, "See ${OAK-SOURCE}.")
    }

    /// The model sometimes writes its own words despite the instruction. Those
    /// are kept: replacing them would delete something a reader was given.
    func testAWrittenLabelIsNotReplaced() {
        let out = render("Runs on a Mac [why a Mac](oak:14).", theme(resolving: "Page 15"))
        XCTAssertEqual(out.string, "Runs on a Mac why a Mac.")
    }

    /// The resolver must not reach ordinary links, which are not citations.
    func testExternalLinksAreUntouched() {
        let out = render("See [${OAK-SOURCE}](https://example.com).", theme(resolving: "Page 15"))
        XCTAssertEqual(out.string, "See ${OAK-SOURCE}.")
    }

    /// Several citations in one paragraph each resolve on their own.
    func testEachCitationResolvesIndependently() {
        var t = MarkdownTheme.oak()
        t.citationLabel = { destination in
            destination == "oak:1" ? "Page 2" : "Page 9"
        }
        let out = render("One [${OAK-SOURCE}](oak:1). Two [${OAK-SOURCE}](oak:8).", t)
        XCTAssertEqual(out.string, "One Page 2. Two Page 9.")
    }
}
