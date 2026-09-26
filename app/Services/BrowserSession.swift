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

    /// User-Agent for live web views. WKWebView's default UA omits the
    /// `Version/.. Safari/..` tokens, so UA-sniffing sites (Google, YouTube, etc.)
    /// fall back to a stripped-down legacy layout. Presenting a complete, current
    /// Safari UA makes those sites serve their modern desktop experience.
    ///
    /// We claim Safari rather than Chrome on purpose: the engine genuinely *is*
    /// WebKit, so a Safari UA stays honest and avoids the engine/UA mismatch class
    /// of bugs (e.g. a site serving Blink-only codecs/APIs that WebKit can't honor).
    /// Dia spoofs Chrome but backs it with a per-site UA-override system; until we
    /// have that safety valve, a single honest Safari UA is the lower-risk default.
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    // MARK: - Address-bar resolution

    /// Resolve raw address-bar input into a navigable URL (URL if it looks like one,
    /// otherwise a search with the user's default engine). Used by the address bar.
    static func resolveInput(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return explicitURL(text) ?? searchURL(text)
    }

    // MARK: - New-tab router

    /// Where a piece of new-tab omnibox text can route to: navigate to a URL or
    /// run a web search. A plain browser omnibox — no AI hand-off.
    enum Route: Equatable, Identifiable {
        /// Run a web search for the text with the default search engine.
        case search(URL)
        /// Navigate directly to a URL.
        case navigate(URL)

        var id: String {
            switch self {
            case .search: return "search"
            case .navigate: return "navigate"
            }
        }
    }

    /// Ordered routing options for omnibox text: URL-like text offers navigate
    /// first (then search as a fallback); anything else is a search. The view
    /// highlights the first row by default and lets the user pick another.
    static func routes(for raw: String) -> [Route] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let search = Route.search(searchURL(text))
        if let url = explicitURL(text) {
            return [.navigate(url), search]
        }
        return [search]
    }

    // MARK: - Heuristics

    /// A bare host or full URL → a navigable URL, defaulting to `https://`.
    /// Returns nil for anything that should be searched (spaces, no dot, etc.).
    static func explicitURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Already a full scheme.
        if let url = URL(string: text), let scheme = url.scheme,
           scheme == "http" || scheme == "https" || scheme == "file" {
            return url
        }

        // Bare host[:port][/path] — no spaces, and has a dot or is localhost.
        let looksLikeHost = !text.contains(" ")
            && (text.contains(".") || text.hasPrefix("localhost"))
        if looksLikeHost, let url = URL(string: "https://\(text)") {
            return url
        }
        return nil
    }

    /// Search URL for a query, using the user's default search engine.
    static func searchURL(_ query: String) -> URL {
        Preferences.shared.browserSearchEngine.searchURL(for: query)
    }
}
