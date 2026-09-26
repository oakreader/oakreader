import Foundation

/// Lightweight HTML `<head>` metadata extraction (Open Graph / Twitter cards / `<title>`).
///
/// Regex-based on purpose: these run against the first chunk of remote pages for
/// link-preview covers, where pulling in a full HTML parser is overkill. The patterns
/// tolerate either attribute order (`property`-then-`content` and vice-versa).
///
/// This is the shared implementation; `ImportService` and `LibraryCoverService` both
/// resolve link previews through here.
enum HTMLMeta {
    /// Content of `<meta property="..." content="...">` (Open Graph, e.g. `og:image`).
    static func content(_ html: String, property: String) -> String? {
        firstMatch(html, attribute: "property", value: property)
    }

    /// Content of `<meta name="..." content="...">` (Twitter cards, e.g. `twitter:image`).
    static func content(_ html: String, name: String) -> String? {
        firstMatch(html, attribute: "name", value: name)
    }

    /// Text of `<title>…</title>`.
    static func title(_ html: String) -> String? {
        guard let range = html.range(of: "(?is)<title[^>]*>(.*?)</title>", options: .regularExpression) else {
            return nil
        }
        let title = String(html[range])
            .replacingOccurrences(of: "(?is)</?title[^>]*>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Resolve a possibly-relative URL string against a base page URL.
    static func resolveURL(_ string: String?, relativeTo base: URL) -> URL? {
        guard let string, !string.isEmpty else { return nil }
        return URL(string: string, relativeTo: base)?.absoluteURL
    }

    private static func firstMatch(_ html: String, attribute: String, value: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: value)
        let patterns = [
            "<meta[^>]+\(attribute)=[\"']\(escaped)[\"'][^>]+content=[\"']([^\"']*)[\"']",
            "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+\(attribute)=[\"']\(escaped)[\"']",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let result = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !result.isEmpty { return result }
            }
        }
        return nil
    }
}
