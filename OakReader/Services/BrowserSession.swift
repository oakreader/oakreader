import Foundation
import WebKit

/// Shared browsing session for live web pages.
///
/// All live `WKWebView`s use the same persistent `WKWebsiteDataStore`, so cookies
/// and login state are shared across tabs and survive relaunches. This is the
/// foundation for later per-space profiles via `WKWebsiteDataStore(forIdentifier:)`.
enum BrowserSession {
    /// Persistent, app-wide data store. `.default()` is already on-disk and shared
    /// by every web view that adopts it — that's what keeps logins alive.
    static let dataStore = WKWebsiteDataStore.default()

    /// Resolve raw address-bar input into a navigable URL.
    ///
    /// - A string that parses as a host (`example.com`, `https://x.y/z`, `localhost:3000`)
    ///   becomes a URL, defaulting to `https://`.
    /// - Anything else (contains spaces, no dot, etc.) becomes a web search.
    static func resolveInput(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Already a full scheme.
        if let url = URL(string: text), let scheme = url.scheme,
           scheme == "http" || scheme == "https" || scheme == "file" {
            return url
        }

        // Looks like a bare host[:port][/path] — no spaces and has a dot or is localhost.
        let looksLikeHost = !text.contains(" ")
            && (text.contains(".") || text.hasPrefix("localhost"))
        if looksLikeHost, let url = URL(string: "https://\(text)") {
            return url
        }

        // Fall back to a search query.
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return URL(string: "https://duckduckgo.com/?q=\(query)")
    }
}
