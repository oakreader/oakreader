import Foundation

/// DuckDuckGo HTML scraping provider — no API key required.
/// Scrapes `https://html.duckduckgo.com/html` for search results.
struct DuckDuckGoSearchProvider: WebSearchProvider {
    let id = "web-search-duckduckgo"
    let displayName = "DuckDuckGo"
    let requiresAPIKey = false
    let envVar: String? = nil
    let signupURL: URL? = nil
    let placeholder = ""

    func search(query: String, count: Int, options: WebSearchOptions) async -> [WebSearchResult] {
        guard !query.isEmpty else { return [] }

        var components = URLComponents(string: "https://html.duckduckgo.com/html")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]

        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8)
        else {
            return []
        }

        return parseResults(html, limit: count)
    }

    // MARK: - HTML Parsing

    private func parseResults(_ html: String, limit: Int) -> [WebSearchResult] {
        // Match result blocks: <a class="result__a" href="...">title</a>
        // and <a class="result__snippet" ...>snippet</a>
        let linkPattern = #"<a\s+[^>]*class="result__a"[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<a\s+[^>]*class="result__snippet"[^>]*>(.*?)</a>"#

        guard let linkRegex = try? NSRegularExpression(pattern: linkPattern, options: [.dotMatchesLineSeparators]),
              let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [.dotMatchesLineSeparators])
        else {
            return []
        }

        let range = NSRange(html.startIndex..., in: html)
        let linkMatches = linkRegex.matches(in: html, range: range)
        let snippetMatches = snippetRegex.matches(in: html, range: range)

        var results: [WebSearchResult] = []

        for (i, linkMatch) in linkMatches.enumerated() where results.count < limit {
            guard let hrefRange = Range(linkMatch.range(at: 1), in: html),
                  let titleRange = Range(linkMatch.range(at: 2), in: html)
            else { continue }

            let rawHref = String(html[hrefRange])
            let rawTitle = String(html[titleRange])

            // DDG wraps URLs in a redirect: //duckduckgo.com/l/?uddg=<encoded_url>&...
            let resolvedURL = Self.resolveDDGRedirect(rawHref)
            guard !resolvedURL.isEmpty,
                  resolvedURL.hasPrefix("http://") || resolvedURL.hasPrefix("https://")
            else { continue }

            let title = Self.stripHTML(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let snippet: String
            if i < snippetMatches.count,
               let snippetRange = Range(snippetMatches[i].range(at: 1), in: html) {
                snippet = Self.stripHTML(String(html[snippetRange]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                snippet = ""
            }

            results.append(WebSearchResult(
                title: title,
                url: resolvedURL,
                snippet: snippet,
                source: displayName
            ))
        }

        return results
    }

    /// Resolve DDG redirect URL. The href looks like:
    /// `//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com&rut=...`
    private static func resolveDDGRedirect(_ href: String) -> String {
        guard let components = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
              let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        else {
            // Not a redirect — return as-is (normalize protocol)
            let url = href.hasPrefix("//") ? "https:" + href : href
            return url
        }
        return uddg
    }

    /// Strip HTML tags from a string.
    private static func stripHTML(_ input: String) -> String {
        input.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
