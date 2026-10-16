import Foundation

/// One `$…$` or `$$…$$` span lifted out of the prose before cmark parsed it.
struct MathSpan: Equatable {
    /// The formula, delimiters stripped.
    let latex: String
    let display: Bool
    /// The span as typed, delimiters included. Shown when no renderer can draw it.
    let source: String
}

/// Swaps math for opaque tokens before cmark sees the prose, and back afterwards.
///
/// cmark reads LaTeX as markdown: `$a_1 * b_2$` grows emphasis, `\\` collapses to
/// `\`, and a `|` inside a formula splits a table cell. ChatGPT's `LatexMarkdownPlugin`
/// does the same swap for the same reason. A token is two private-use characters
/// around an index into the span table; cmark treats them as plain letters, so a
/// token never starts or ends emphasis and never splits a text node.
///
/// Code spans and fenced code are copied through untouched.
enum MathPlaceholders {
    static let open: Character = "\u{E000}"
    static let close: Character = "\u{E001}"

    enum Piece: Equatable {
        case text(String)
        case math(MathSpan)
    }

    static func protect(_ markdown: String) -> (text: String, spans: [MathSpan]) {
        guard markdown.contains("$") else { return (markdown, []) }
        let chars = Array(markdown)
        let n = chars.count
        var out = ""
        out.reserveCapacity(markdown.utf8.count)
        var spans: [MathSpan] = []
        var i = 0
        var atLineStart = true
        var fence: (char: Character, length: Int)?

        func token(_ span: MathSpan) {
            out.append(open)
            out += String(spans.count)
            out.append(close)
            spans.append(span)
        }

        while i < n {
            if atLineStart {
                atLineStart = false
                let lineEnd = chars[i...].firstIndex(of: "\n") ?? n
                if let marker = fenceMarker(chars[i..<lineEnd]) {
                    if let open = fence {
                        if marker.char == open.char, marker.length >= open.length { fence = nil }
                    } else {
                        fence = marker
                    }
                }
                if fence != nil || fenceMarker(chars[i..<lineEnd]) != nil {
                    out += String(chars[i..<lineEnd])
                    if lineEnd < n { out.append("\n") }
                    i = lineEnd + 1
                    atLineStart = true
                    continue
                }
            }

            let c = chars[i]
            switch c {
            case "\n":
                out.append(c)
                i += 1
                atLineStart = true
            case "\\" where i + 1 < n:
                // `\$` is a literal dollar and `` \` `` a literal backtick: cmark owns both.
                out.append(c)
                out.append(chars[i + 1])
                i += 2
            case "`":
                let run = runLength(chars, from: i, of: "`")
                if let end = closingBacktickRun(chars, after: i + run, length: run) {
                    out += String(chars[i..<end])
                    i = end
                } else {
                    out += String(repeating: "`", count: run)
                    i += run
                }
            case "$" where startsWith(chars, at: i, citation):
                // `${OAK-SOURCE}` is the citation label slot, not a formula. Left alone,
                // `[${OAK-SOURCE}](oak:1) and [${OAK-SOURCE}](oak:2)` reads as one span.
                out += String(citation)
                i += citation.count
            case "$":
                if i + 1 < n, chars[i + 1] == "$" {
                    if let end = closingDisplay(chars, after: i + 2) {
                        let body = String(chars[(i + 2)..<end])
                        if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            token(MathSpan(
                                latex: body.trimmingCharacters(in: .whitespacesAndNewlines),
                                display: true,
                                source: String(chars[i..<(end + 2)])))
                            i = end + 2
                            continue
                        }
                    }
                    out += "$$"
                    i += 2
                } else if let end = closingInline(chars, after: i + 1) {
                    token(MathSpan(
                        latex: String(chars[(i + 1)..<end]),
                        display: false,
                        source: String(chars[i...end])))
                    i = end + 1
                } else {
                    out.append(c)
                    i += 1
                }
            default:
                out.append(c)
                i += 1
            }
        }
        return (out, spans)
    }

    /// Splits a cmark text literal back into prose and math.
    static func pieces(in literal: String, spans: [MathSpan]) -> [Piece] {
        guard !spans.isEmpty, literal.contains(open) else { return [.text(literal)] }
        var pieces: [Piece] = []
        var text = ""
        var rest = literal[...]
        while let start = rest.firstIndex(of: open) {
            text += rest[..<start]
            let afterOpen = rest.index(after: start)
            if let end = rest[afterOpen...].firstIndex(of: close),
               let index = Int(rest[afterOpen..<end]), spans.indices.contains(index) {
                if !text.isEmpty { pieces.append(.text(text)) }
                text = ""
                pieces.append(.math(spans[index]))
                rest = rest[rest.index(after: end)...]
            } else {
                text.append(open)
                rest = rest[afterOpen...]
            }
        }
        text += rest
        if !text.isEmpty { pieces.append(.text(text)) }
        return pieces
    }

    /// Puts every span back as typed. For literals that are not prose: code, HTML.
    static func restoreSource(_ literal: String, spans: [MathSpan]) -> String {
        guard !spans.isEmpty, literal.contains(open) else { return literal }
        return pieces(in: literal, spans: spans).map {
            switch $0 {
            case .text(let text): return text
            case .math(let span): return span.source
            }
        }.joined()
    }

    // MARK: scanning

    private static let citation = Array(StreamingMarkdownSanitizer.citationPlaceholder)

    private static func startsWith(_ chars: [Character], at start: Int, _ prefix: [Character]) -> Bool {
        start + prefix.count <= chars.count && chars[start..<(start + prefix.count)].elementsEqual(prefix)
    }

    /// A ``` or ~~~ fence opening the line, after at most three spaces.
    private static func fenceMarker(_ line: ArraySlice<Character>) -> (char: Character, length: Int)? {
        var index = line.startIndex
        var spaces = 0
        while index < line.endIndex, line[index] == " ", spaces < 3 {
            index += 1
            spaces += 1
        }
        guard index < line.endIndex, line[index] == "`" || line[index] == "~" else { return nil }
        let char = line[index]
        var length = 0
        while index < line.endIndex, line[index] == char {
            index += 1
            length += 1
        }
        return length >= 3 ? (char, length) : nil
    }

    private static func runLength(_ chars: [Character], from start: Int, of char: Character) -> Int {
        var end = start
        while end < chars.count, chars[end] == char { end += 1 }
        return end - start
    }

    /// End index (exclusive) of the backtick run of exactly `length` that closes a
    /// code span, or nil when the run is never closed and is literal text.
    private static func closingBacktickRun(_ chars: [Character], after start: Int, length: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "`" {
                let run = runLength(chars, from: i, of: "`")
                if run == length { return i + run }
                i += run
            } else {
                i += 1
            }
        }
        return nil
    }

    /// Index of the `$$` closing a display span. A blank line ends the search: a
    /// span never crosses paragraphs, and an unclosed `$$` stays text while it streams.
    private static func closingDisplay(_ chars: [Character], after start: Int) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "\n", isBlankLine(chars, from: i + 1) { return nil }
            if chars[i] == "$", chars[i + 1] == "$" { return i }
            i += 1
        }
        return nil
    }

    private static func isBlankLine(_ chars: [Character], from start: Int) -> Bool {
        var i = start
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        return i >= chars.count || chars[i] == "\n"
    }

    /// Index of the `$` closing an inline span, by Pandoc's rule: the opener is not
    /// followed by a space, the closer is not preceded by one and not followed by a
    /// digit. That keeps `costs $5 and $10` as prose. Inline math stays on one line.
    private static func closingInline(_ chars: [Character], after start: Int) -> Int? {
        guard start < chars.count, !chars[start].isWhitespace, chars[start] != "$" else { return nil }
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { return nil }
            if c == "\\" { i += 2; continue }
            if c == "$" {
                // A citation slot is never a closer: `costs **$1**. [${OAK-SOURCE}](oak:3)`
                // would otherwise read as one formula from the price to the citation.
                if startsWith(chars, at: i, citation) { return nil }
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if chars[i - 1].isWhitespace || next == "$" || next?.isNumber == true { return nil }
                return i
            }
            i += 1
        }
        return nil
    }
}
