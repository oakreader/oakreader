import Foundation
import SwiftUI
import Textual

// MARK: - Memoized Block View
//
// `Equatable` is the load-bearing piece: when the enclosing chat view re-renders
// at the streaming commit rate, SwiftUI re-evaluates the `ForEach` closure and
// builds a `ChatMarkdownBlockView` value for every block — but `.equatable()`
// short-circuits `body` for any block whose `text`/`seal` are unchanged, so
// `StructuredText` (and Textual's parser) only runs for the tail.

struct ChatMarkdownBlockView: View, Equatable {
    let text: String
    /// Seal unmatched markdown markers (only for the still-growing tail).
    let seal: Bool
    /// Enable Textual text selection (only for settled, non-streaming content —
    /// selection mid-stream can wedge Textual's attachment layout; see
    /// `ChatBubbleView.chatMarkdown`).
    let selectable: Bool

    var body: some View {
        // protect + seal run per-block, so `.equatable()`-skipped settled blocks
        // never pay for them again after their first (and only) render.
        let protected = text.protectingMathBackslashes()
        let source = seal ? protected.sealIncompleteMarkdown() : protected
        let base = StructuredText(markdown: source, syntaxExtensions: [.math])
            .textual.headingStyle(ChatHeadingStyle())
            .font(OakStyle.ChatFont.messageBody)
        if selectable {
            base.textual.textSelection(.enabled)
        } else {
            base
        }
    }

    static func == (lhs: ChatMarkdownBlockView, rhs: ChatMarkdownBlockView) -> Bool {
        lhs.text == rhs.text && lhs.seal == rhs.seal && lhs.selectable == rhs.selectable
    }
}

// MARK: - Math backslash protection

extension String {
    // Display math $$...$$ (dotall) or inline math $...$ (no newlines).
    // swiftlint:disable:next force_try
    private static let mathDelimiterPattern = try! NSRegularExpression(
        pattern: #"\$\$(.+?)\$\$|\$(?!\$)((?:\\\$|[^$\n])+)\$"#,
        options: [.dotMatchesLineSeparators]
    )

    /// Doubles backslashes inside math delimiters (`$$…$$` and `$…$`) so they
    /// survive Foundation's markdown parser. Foundation treats `\\` as a valid
    /// CommonMark escape (producing `\`), destroying LaTeX line breaks and
    /// literal braces before Textual's math regex ever sees them.
    func protectingMathBackslashes() -> String {
        let ns = self as NSString
        guard ns.length > 0 else { return self }
        var result = ""
        var cursor = 0

        Self.mathDelimiterPattern.enumerateMatches(
            in: self, range: NSRange(location: 0, length: ns.length)
        ) { match, _, _ in
            guard let match else { return }
            let fullRange = match.range

            result += ns.substring(with: NSRange(location: cursor,
                                                 length: fullRange.location - cursor))

            // group 1 = $$…$$, group 2 = $…$
            let isBlock = match.range(at: 1).location != NSNotFound
            let contentRange = match.range(at: isBlock ? 1 : 2)
            var content = ns.substring(with: contentRange)
            // Textual splits markdown into blocks at newlines *before* its math
            // tokenizer runs, so a multi-line display equation (`$$` on its own
            // line, body on the next) never matches `(?s)\$\$(.+?)\$\$` and renders
            // as raw LaTeX. Collapse soft newlines inside `$$…$$` to spaces so the
            // whole equation stays on one line and tokenizes. LaTeX treats a bare
            // newline as whitespace, and explicit `\\` line breaks survive intact.
            if isBlock {
                content = content.replacingOccurrences(of: "\n", with: " ")
            }
            let protected = content.replacingOccurrences(of: "\\", with: "\\\\")

            result += isBlock ? "$$\(protected)$$" : "$\(protected)$"
            cursor = fullRange.location + fullRange.length
        }

        result += ns.substring(from: cursor)
        return result
    }

    /// True if the string contains a closed math span (`$$…$$` or `$…$`) — the
    /// same delimiters Textual's `.math` extension turns into layout attachments.
    /// Used to keep text selection OFF for math blocks: a fragment with BOTH the
    /// attachment overlay and the selection overlay (each a `GeometryReader`
    /// inside a `Text.LayoutKey` preference reader) forms two competing
    /// layout→preference→layout loops that never converge and spin the main
    /// thread. Math-alone or selection-alone each converge; only the pair wedges.
    func containsMath() -> Bool {
        let ns = self as NSString
        guard ns.length > 0 else { return false }
        return Self.mathDelimiterPattern.firstMatch(
            in: self, range: NSRange(location: 0, length: ns.length)
        ) != nil
    }
}
