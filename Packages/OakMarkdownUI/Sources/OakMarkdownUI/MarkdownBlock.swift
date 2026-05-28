import Foundation

/// What kind of view renders a block. The block-stack routes on this.
public enum MarkdownBlockKind: Equatable {
    case prose                      // paragraphs, headings, lists, blockquotes, inline code/math
    case code(language: String?)    // fenced code → CodeBlockView (Highlightr)
    case mathDisplay                // standalone $$…$$ → MathBlockView (SwiftMath)
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
        return .prose
    }
}
