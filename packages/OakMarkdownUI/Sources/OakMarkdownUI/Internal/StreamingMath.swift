import Foundation

/// The part of a display formula that can be drawn while the rest still streams.
///
/// An unclosed `$$` used to show as source until its close arrived, and a long
/// formula streamed in as raw LaTeX for seconds. This closes the groups still open
/// (`{`, `\left`, `\begin{…}`) and asks SwiftUIMath to lay the result out. When that
/// fails, typically on a half-typed command or a `\frac` missing its second
/// argument, it drops the last token and tries again. The formula grows as it
/// arrives instead of appearing at once.
///
/// Stats are not recorded: a partial formula is not a formula the model wrote.
@MainActor
enum StreamingMath {
    /// Tries at most this many prefixes per call; each is one SwiftUIMath layout.
    static let maxAttempts = 24

    /// The longest drawable prefix of `latex` with its open groups closed, or nil.
    /// Text SwiftUIMath has no glyphs for waits for the close and the KaTeX path.
    static func drawablePrefix(_ latex: String, fontSize: CGFloat) -> String? {
        guard !MathRoute.hasNonLatinText(latex) else { return nil }
        var tokens = tokenize(latex)
        for _ in 0..<maxAttempts {
            while let last = tokens.last, last.allSatisfy(\.isWhitespace) { tokens.removeLast() }
            guard !tokens.isEmpty else { return nil }
            let candidate = closingOpenGroups(tokens.joined())
            if MathRoute.measures(MarkdownCompat.normalizeLaTeX(candidate), display: true, fontSize: fontSize) {
                return candidate
            }
            tokens.removeLast()
        }
        return nil
    }

    /// `\name`, `\` plus one character, or one character.
    static func tokenize(_ latex: String) -> [String] {
        var tokens: [String] = []
        var i = latex.startIndex
        while i < latex.endIndex {
            var j = latex.index(after: i)
            if latex[i] == "\\", j < latex.endIndex {
                if latex[j].isLetter {
                    while j < latex.endIndex, latex[j].isLetter { j = latex.index(after: j) }
                } else {
                    j = latex.index(after: j)
                }
            }
            tokens.append(String(latex[i..<j]))
            i = j
        }
        return tokens
    }

    /// `latex` with a closer appended for every `{`, `\left` and `\begin{env}`
    /// still open, innermost first.
    static func closingOpenGroups(_ latex: String) -> String {
        var closers: [String] = []
        let tokens = tokenize(latex)
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "{": closers.append("}")
            case "}": if closers.last == "}" { closers.removeLast() }
            case "\\left": closers.append("\\right.")
            case "\\right": if closers.last == "\\right." { closers.removeLast() }
            case "\\begin", "\\end":
                // The environment name: `{` letters `}`, all of it already arrived.
                var name = ""
                var k = index + 1
                if k < tokens.count, tokens[k] == "{" {
                    k += 1
                    while k < tokens.count, tokens[k] != "}" { name += tokens[k]; k += 1 }
                }
                guard k < tokens.count, !name.isEmpty else { return latex }
                if token == "\\begin" {
                    closers.append("\\end{\(name)}")
                } else if closers.last == "\\end{\(name)}" {
                    closers.removeLast()
                }
                index = k
            default: break
            }
            index += 1
        }
        return latex + closers.reversed().joined()
    }
}
