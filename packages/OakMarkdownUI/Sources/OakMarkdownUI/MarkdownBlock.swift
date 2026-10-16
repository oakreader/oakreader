import Foundation

/// What kind of view renders a block. The block-stack routes on this.
public enum MarkdownBlockKind: Equatable {
    case prose                          // paragraphs, headings, lists, blockquotes, inline code/math
    case code(language: String?)        // fenced code → CodeBlockView (Highlightr)
    case mathDisplay                    // standalone $$…$$ → MathBlockView (SwiftMath)
    case mathDisplayOpen                // trailing `$$…` whose close has not arrived yet
    case table                          // GFM pipe table → TableBlockView (SwiftUI Grid)
    case image(url: String, alt: String) // standalone ![alt](url) → ImageBlockView (fullscreen-able)
}

/// One top-level block. Streaming is append-only, so a block's index is stable;
/// `isSettled == true` once a blank line (or closed fence) follows it → frozen,
/// never re-rendered. Only the trailing block re-renders as text streams in.
public struct MarkdownBlock: Identifiable, Equatable {
    public let id: Int
    public let text: String
    public let kind: MarkdownBlockKind
    public let isSettled: Bool
}

/// Splits markdown into blank-line-separated, fence-aware blocks and classifies each.
/// Fence-aware: blank lines inside ``` / ~~~ do NOT split (so a code block stays whole).
public enum MarkdownBlockSplitter {
    public static func split(_ markdown: String) -> [MarkdownBlock] {
        if markdown.isEmpty { return [] }
        let markdown = isolateDisplayMath(markdown)

        var groups: [[Substring]] = []
        var current: [Substring] = []
        var inFence = false
        var fenceChar: Character = "`"

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            let isBacktick = trimmed.hasPrefix("```")
            let isTilde = trimmed.hasPrefix("~~~")

            if isBacktick || isTilde {
                let marker: Character = isTilde ? "~" : "`"
                if !inFence {
                    inFence = true
                    fenceChar = marker
                } else if marker == fenceChar {
                    inFence = false
                }
                current.append(line)
                continue
            }
            if inFence {
                current.append(line)
                continue
            }
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                if !current.isEmpty {
                    groups.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { groups.append(current) }

        groups = mergeSplitTables(groups)

        let last = groups.count - 1
        return groups.enumerated().map { index, lines in
            let text = lines.joined(separator: "\n")
            return MarkdownBlock(
                id: index,
                text: text,
                kind: classify(lines: lines, text: text),
                isSettled: index != last
            )
        }
    }

    /// Rewrites display math so each `$$…$$` span stands alone as a block.
    ///
    /// Display math only renders when its block starts and ends with `$$`. Models
    /// often write `如$$` with prose on the same line, or put a blank line inside
    /// the span. Either way the span fell through to cmark, which treats the LaTeX
    /// as markdown: `\\` becomes `\` and a trailing `\` becomes a line break.
    /// This pass moves every `$$` span onto its own lines, fenced by blank lines,
    /// and drops blank lines inside it. `\[…\]` is read as `$$…$$` and `\(…\)` as
    /// `$…$`. Code fences and inline code spans are left untouched.
    ///
    /// An unclosed `$$` at the end is kept as typed, blank lines included. While
    /// streaming, the close has not arrived yet. In a finished reply, it is a stray
    /// `$$`, and swallowing the rest of the reply into one block would be worse.
    static func isolateDisplayMath(_ markdown: String) -> String {
        guard markdown.contains("$$") || markdown.contains("\\[") || markdown.contains("\\(") else {
            return markdown
        }

        var out: [String] = []
        var inFence = false
        var fenceChar: Character = "`"
        var inMath = false
        // Every line of the open span as typed, blank lines included.
        var mathLines: [String] = []

        func closeMath() {
            out.append("$$")
            out.append(contentsOf: mathLines.filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            })
            out.append("$$")
            out.append("")
            inMath = false
            mathLines = []
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.drop { $0 == " " || $0 == "\t" }
            if !inMath, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker: Character = trimmed.hasPrefix("~~~") ? "~" : "`"
                if !inFence {
                    inFence = true
                    fenceChar = marker
                } else if marker == fenceChar {
                    inFence = false
                }
                out.append(String(rawLine))
                continue
            }
            if inFence {
                out.append(String(rawLine))
                continue
            }

            let parts = splitOnDisplayDelimiter(normalizeMathDelimiters(String(rawLine)))
            var prose = ""
            for (index, part) in parts.enumerated() {
                if index > 0 {
                    // A `$$` sits between parts[index-1] and parts[index].
                    if inMath {
                        closeMath()
                    } else {
                        if !prose.trimmingCharacters(in: .whitespaces).isEmpty { out.append(prose) }
                        prose = ""
                        out.append("")
                        inMath = true
                    }
                }
                if inMath {
                    mathLines.append(part)
                } else {
                    prose += part
                }
            }
            if !inMath, parts.count == 1 || !prose.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(prose)
            }
        }
        if inMath {
            out.append("$$" + (mathLines.first ?? ""))
            out.append(contentsOf: mathLines.dropFirst())
        }
        return out.joined(separator: "\n")
    }

    /// Splits a line on `$$`, skipping any `$$` inside a backtick code span,
    /// so `` `echo $$` `` stays prose.
    private static func splitOnDisplayDelimiter(_ line: String) -> [String] {
        guard line.contains("$$") else { return [line] }
        var parts: [String] = []
        var current = ""
        var inCode = false
        var index = line.startIndex
        while index < line.endIndex {
            let char = line[index]
            if char == "`" {
                inCode.toggle()
            } else if !inCode, char == "$", line.index(after: index) < line.endIndex,
                      line[line.index(after: index)] == "$" {
                parts.append(current)
                current = ""
                index = line.index(index, offsetBy: 2)
                continue
            }
            current.append(char)
            index = line.index(after: index)
        }
        parts.append(current)
        return parts
    }

    // `\(…\)` with neither delimiter preceded by a backslash, so a LaTeX line
    // break `\\(` inside a matrix row is not read as a delimiter.
    private static let parenMathRegex = try! NSRegularExpression(
        pattern: #"(?<!\\)\\\((.+?)(?<!\\)\\\)"#)

    /// `\[` / `\]` → `$$`, and `\(` / `\)` → `$`. A `\[` counts only at the start
    /// of a line and `\]` only at the end, so an escaped bracket in prose such as
    /// `\[1\]` mid-sentence is left alone.
    private static func normalizeMathDelimiters(_ line: String) -> String {
        var line = line
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\\["), let range = line.range(of: "\\[") {
            line.replaceSubrange(range, with: "$$")
        }
        let tail = line.trimmingCharacters(in: .whitespaces)
        if tail.hasSuffix("\\]"), !tail.hasSuffix("\\\\]"),
           let range = line.range(of: "\\]", options: .backwards) {
            line.replaceSubrange(range, with: "$$")
        }
        if line.contains("\\(") {
            let ns = line as NSString
            line = parenMathRegex.stringByReplacingMatches(
                in: line, range: NSRange(location: 0, length: ns.length),
                withTemplate: "\\$$1\\$")
        }
        return line
    }

    /// Rejoins a table that arrived with blank lines between its rows.
    ///
    /// Models routinely emit GFM tables as
    /// `| a | b |` ⏎⏎ `|---|---|` ⏎⏎ `| 1 | 2 |`. That is malformed — a blank
    /// line ends a table — but it is plainly meant as one, and splitting on
    /// blank lines leaves every row its own prose block, pipes and all. A run of
    /// consecutive pipe-prefixed groups is merged back together, and only kept
    /// merged when the result actually validates as a table, so prose that
    /// happens to start with a pipe is left alone.
    private static func mergeSplitTables(_ groups: [[Substring]]) -> [[Substring]] {
        guard groups.count >= 2 else { return groups }

        func isPipeRow(_ line: Substring) -> Bool {
            line.drop { $0 == " " || $0 == "\t" }.hasPrefix("|")
        }
        func isPipeGroup(_ group: [Substring]) -> Bool {
            !group.isEmpty && group.allSatisfy(isPipeRow)
        }

        var merged: [[Substring]] = []
        var index = 0
        while index < groups.count {
            guard isPipeGroup(groups[index]) else {
                merged.append(groups[index])
                index += 1
                continue
            }
            var runEnd = index
            while runEnd + 1 < groups.count, isPipeGroup(groups[runEnd + 1]) {
                runEnd += 1
            }
            let run = Array(groups[index...runEnd])
            let flattened = run.flatMap { $0 }
            if run.count > 1, isPipeTable(lines: flattened) {
                merged.append(flattened)
            } else {
                merged.append(contentsOf: run)
            }
            index = runEnd + 1
        }
        return merged
    }

    private static func classify(lines: [Substring], text: String) -> MarkdownBlockKind {
        let first = lines.first?.drop { $0 == " " || $0 == "\t" } ?? ""
        if first.hasPrefix("```") || first.hasPrefix("~~~") {
            let lang = first.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return .code(language: lang.isEmpty ? nil : lang)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 4, trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$") {
            return .mathDisplay
        }
        // `isolateDisplayMath` leaves an unclosed `$$` only at the end of the reply.
        if trimmed.hasPrefix("$$") {
            return .mathDisplayOpen
        }
        if isPipeTable(lines: lines) {
            return .table
        }
        if let img = singleImage(in: text) {
            return .image(url: img.url, alt: img.alt)
        }
        return .prose
    }

    /// A block that is *only* a single markdown image (`![alt](url)`, nothing else)
    /// renders as its own `ImageBlockView` so it can carry a fullscreen button. An
    /// image sitting inside a paragraph of prose stays inline (no own view). A
    /// half-streamed `![alt](ur` won't match, so it stays prose until the URL closes.
    private static let singleImageRegex = try! NSRegularExpression(
        pattern: #"^!\[([^\]]*)\]\(([^)\s]+)\)$"#)

    private static func singleImage(in text: String) -> (alt: String, url: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n") else { return nil }
        let ns = trimmed as NSString
        guard let m = singleImageRegex.firstMatch(
            in: trimmed, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))
    }

    /// GFM pipe-table shape: a header line containing `|`, followed by a
    /// separator line of the form `| --- | :---: |` (cells of dashes with
    /// optional leading/trailing colons for alignment). Anything else falls
    /// through to prose so stray pipes in text don't get misclassified.
    private static func isPipeTable(lines: [Substring]) -> Bool {
        guard lines.count >= 2 else { return false }
        let header = lines[0].drop { $0 == " " || $0 == "\t" }
        guard header.contains("|") else { return false }
        let separator = lines[1].trimmingCharacters(in: .whitespaces)
        guard !separator.isEmpty else { return false }
        // Strip optional leading/trailing pipe, then validate every cell.
        var body = separator
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        let cells = body.split(separator: "|", omittingEmptySubsequences: false)
        guard !cells.isEmpty else { return false }
        for cell in cells {
            let token = cell.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { return false }
            var scalars = Substring(token)
            if scalars.first == ":" { scalars = scalars.dropFirst() }
            if scalars.last == ":" { scalars = scalars.dropLast() }
            guard !scalars.isEmpty, scalars.allSatisfy({ $0 == "-" }) else { return false }
        }
        return true
    }
}
