import Foundation

/// What kind of view renders a block. The block-stack routes on this.
public enum MarkdownBlockKind: Equatable {
    case prose                          // paragraphs, headings, lists, blockquotes, inline code/math
    case code(language: String?)        // fenced code → CodeBlockView (Highlightr)
    case mathDisplay                    // standalone $$…$$ → MathBlockView (SwiftMath)
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
