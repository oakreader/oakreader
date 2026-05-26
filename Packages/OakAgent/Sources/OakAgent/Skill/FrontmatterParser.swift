import Foundation

/// Parsed result from a Markdown file with YAML frontmatter.
public struct FrontmatterResult: Sendable {
    /// Key-value pairs from the YAML frontmatter block.
    public let frontmatter: [String: String]
    /// The Markdown body after the closing `---`.
    public let body: String
}

/// Minimal YAML frontmatter parser for `SKILL.md` files.
///
/// Handles simple `key: value` pairs between `---` delimiters. Does not support
/// nested YAML, arrays, or multi-line values — only the subset used by the
/// [Agent Skills](https://agentskills.io) spec.
public enum FrontmatterParser {

    /// Parse a Markdown string with optional YAML frontmatter.
    ///
    /// Returns `nil` if the content does not start with a `---` delimiter.
    public static func parse(_ content: String) -> FrontmatterResult? {
        let lines = content.components(separatedBy: .newlines)

        guard let firstLine = lines.first,
              firstLine.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }

        // Find the closing delimiter
        var closingIndex: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                closingIndex = i
                break
            }
        }

        guard let endIndex = closingIndex else {
            return nil
        }

        // Parse key-value pairs
        var frontmatter: [String: String] = [:]
        for i in 1..<endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[trimmed.startIndex..<colonIndex]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let rawValue = trimmed[trimmed.index(after: colonIndex)...]
                .trimmingCharacters(in: .whitespaces)
            let value = stripQuotes(rawValue)

            if !key.isEmpty {
                frontmatter[key] = value
            }
        }

        // Body is everything after the closing ---
        let bodyLines = Array(lines[(endIndex + 1)...])
        let body = bodyLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return FrontmatterResult(frontmatter: frontmatter, body: body)
    }

    /// Strip a single layer of matching outer quotes from a YAML scalar.
    ///
    /// Matches how a real YAML parser unquotes `key: "value"` / `key: 'value'`.
    /// For double-quoted strings, common backslash escapes are also unescaped.
    private static func stripQuotes(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last else {
            return value
        }

        if first == "\"" && last == "\"" {
            let inner = String(value.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }

        if first == "'" && last == "'" {
            // YAML single quotes escape a literal quote by doubling it.
            return String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }

        return value
    }
}
