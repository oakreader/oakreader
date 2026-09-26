import Foundation

/// Minimal `.gitignore`-style matcher used during skill discovery.
///
/// Mirrors the subset of git ignore semantics the upstream pi loader relies on:
/// comments (`#`), blank lines, negation (`!`), anchored patterns (containing a
/// slash), basename patterns (matched at any depth), `*` / `?` / `**` wildcards,
/// and directory-only patterns (trailing `/`). Rules are evaluated in order with
/// last-match-wins, so a later negation can re-include a previously ignored path.
///
/// The matcher is a value type: passing a copy into a recursion gives children the
/// accumulated parent rules without letting sibling directories pollute each other.
struct GitignoreMatcher {
    private struct Rule {
        let regex: NSRegularExpression
        let negated: Bool
    }

    private var rules: [Rule] = []

    var isEmpty: Bool { rules.isEmpty }

    /// Add raw ignore-file lines, anchoring them under `prefix` — a posix-style,
    /// root-relative directory path ending in `/` (empty for the scan root).
    mutating func add(lines: [String], prefix: String) {
        for raw in lines {
            if let rule = Self.makeRule(from: raw, prefix: prefix) {
                rules.append(rule)
            }
        }
    }

    /// Whether `relativePath` (posix, root-relative, no leading slash) is ignored.
    /// Directory entries should be passed with a trailing slash so directory-only
    /// patterns can match them.
    func isIgnored(_ relativePath: String) -> Bool {
        var ignored = false
        let range = NSRange(relativePath.startIndex..., in: relativePath)
        for rule in rules where rule.regex.firstMatch(in: relativePath, range: range) != nil {
            ignored = !rule.negated
        }
        return ignored
    }

    // MARK: - Rule compilation

    private static func makeRule(from rawLine: String, prefix: String) -> Rule? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }

        var line = trimmed
        var negated = false
        if line.hasPrefix("!") {
            negated = true
            line.removeFirst()
        } else if line.hasPrefix("\\!") || line.hasPrefix("\\#") {
            line.removeFirst() // drop the escaping backslash, keep the literal char
        }

        var directoryOnly = false
        if line.hasSuffix("/") {
            directoryOnly = true
            line.removeLast()
        }
        if line.isEmpty { return nil }

        // A pattern is anchored to the ignore root if it contains a slash; otherwise
        // it matches a basename at any depth.
        let anchored = line.contains("/")
        if line.hasPrefix("/") { line.removeFirst() }

        let core = globToRegex(line)
        let body = prefix.isEmpty ? core : NSRegularExpression.escapedPattern(for: prefix) + core

        let anchorPrefix = (anchored || !prefix.isEmpty) ? "^" : "(?:^|.*/)"
        // Ignoring a node also ignores everything nested beneath it.
        let tail = directoryOnly ? "/.*$" : "(?:/.*)?$"

        guard let regex = try? NSRegularExpression(pattern: anchorPrefix + body + tail) else {
            return nil
        }
        return Rule(regex: regex, negated: negated)
    }

    private static func globToRegex(_ glob: String) -> String {
        var result = ""
        let chars = Array(glob)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    // `**` matches across path separators.
                    i += 1
                    if i + 1 < chars.count && chars[i + 1] == "/" {
                        i += 1
                        result += "(?:.*/)?"
                    } else {
                        result += ".*"
                    }
                } else {
                    result += "[^/]*"
                }
            case "?":
                result += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                result += "\\" + String(c)
            default:
                result += String(c)
            }
            i += 1
        }
        return result
    }
}
