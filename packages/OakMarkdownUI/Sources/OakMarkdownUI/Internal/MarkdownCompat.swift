import Foundation

/// Rewrites for input the parsers reject but models write all the time.
enum MarkdownCompat {

    // MARK: CJK emphasis

    /// Zero-width space used as a flanking shim; stripped again after rendering.
    static let shim = "\u{200B}"

    // CommonMark's flanking rules refuse a `**` that sits between punctuation and a
    // letter: `**学习方式：**每` does not close, because the closer is preceded by `：`
    // and followed by `每`. English puts a space there; CJK never does. A shim between
    // the punctuation and the run makes the run flank a non-punctuation character, so
    // it opens or closes as the writer meant.
    private static let cjk = #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]"#
    /// Punctuation other than `*`, which is itself `\p{P}` and would split the run.
    private static let punct = #"[^\P{P}*]"#
    private static let closerRegex = try! NSRegularExpression(
        pattern: "(" + punct + #")(\*{1,3})(?="# + cjk + ")"
    )
    private static let openerRegex = try! NSRegularExpression(
        pattern: "(?<=" + cjk + #")(\*{1,3})("# + punct + ")"
    )

    static func shimCJKEmphasis(_ markdown: String) -> String {
        guard markdown.contains("*") else { return markdown }
        var text = markdown
        for (regex, template) in [(closerRegex, "$1\(shim)$2"), (openerRegex, "$1\(shim)$2")] {
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        return text
    }

    // MARK: LaTeX

    /// The source SwiftUIMath parses: shims removed, unknown commands rewritten
    /// through `LatexCommands`. An unknown command fails the whole formula.
    static func normalizeLaTeX(_ latex: String) -> String {
        LatexCommands.rewrite(latex.replacingOccurrences(of: shim, with: ""))
    }
}
