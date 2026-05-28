import Foundation
import SwiftUI
import Textual

// MARK: - Markdown Block Splitting
//
// During streaming, `ChatBubbleView` previously rebuilt one `StructuredText`
// over the *entire* message on every commit, so Textual re-parsed and
// re-laid-out the whole document each frame — O(message length) per frame,
// which is the root cause of the "long message → jank" problem.
//
// This splits the markdown into top-level blocks separated by blank lines
// (fence-aware: blank lines inside ``` / ~~~ code fences do NOT split). All
// blocks except the last are "settled" — a blank line follows them, so in
// CommonMark they can no longer merge with later content and their rendering
// is final. Only the last block (the "active tail") is still growing.
//
// Rendered through a `ForEach` of `EquatableView`s keyed by a stable id, this
// means: while streaming, only the tail block re-parses each commit; every
// settled block above keeps a stable identity and unchanged content, so
// SwiftUI skips its body entirely and Textual never re-parses it. This mirrors
// Xcode's `AnimatableStreamingTextViewModel.Segment` / `Snapshot` diffing
// (fine-grained invalidation), adapted to Textual's view-based renderer.

struct MarkdownBlock: Identifiable, Equatable {
    /// Stable identity. Streaming is append-only, so a block's index never
    /// changes once created; the tail keeps a fixed index and updates in place.
    let id: Int
    let text: String
    /// `false` once a blank line (or closed fence) follows the block — its
    /// rendering is final and it can be frozen.
    let isSettled: Bool
}

enum MarkdownBlockSplitter {
    /// Splits `markdown` into blank-line-separated, fence-aware blocks.
    /// The last returned block is the active tail (`isSettled == false`);
    /// all earlier blocks are settled.
    static func split(_ markdown: String) -> [MarkdownBlock] {
        if markdown.isEmpty { return [] }

        var blocks: [[Substring]] = []
        var current: [Substring] = []
        var inFence = false
        var fenceChar: Character = "`"

        // `components(separatedBy:)` keeps a trailing empty element for a final
        // "\n", which correctly flushes the current block (blank-line boundary).
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmedLeading = line.drop { $0 == " " || $0 == "\t" }
            let isBacktickFence = trimmedLeading.hasPrefix("```")
            let isTildeFence = trimmedLeading.hasPrefix("~~~")

            if isBacktickFence || isTildeFence {
                let marker: Character = isTildeFence ? "~" : "`"
                if !inFence {
                    inFence = true
                    fenceChar = marker
                } else if marker == fenceChar {
                    // A closing fence must match the opening fence character.
                    inFence = false
                }
                current.append(line)
                continue
            }

            if inFence {
                current.append(line)
                continue
            }

            // Outside a fence: a blank line is a block boundary.
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                if !current.isEmpty {
                    blocks.append(current)
                    current = []
                }
                // Collapse consecutive blank lines — don't emit empty blocks.
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current) }

        let lastIndex = blocks.count - 1
        return blocks.enumerated().map { index, lines in
            MarkdownBlock(
                id: index,
                text: lines.joined(separator: "\n"),
                isSettled: index != lastIndex
            )
        }
    }
}

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
