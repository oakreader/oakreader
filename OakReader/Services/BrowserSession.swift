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
    /// otherwise a Google search). Used by the browser chrome's address bar.
    static func resolveInput(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return explicitURL(text) ?? googleSearch(text)
    }

    // MARK: - New-tab router

    /// Where a piece of new-tab omnibox text can route to. Mirrors Dia's Cmd+T
    /// behavior: a single input that resolves to navigate / web-search / ask-AI.
    enum Route: Equatable, Identifiable {
        /// Hand the text to the AI agent chat.
        case ask(String)
        /// Run a web search (Google) for the text.
        case search(URL)
        /// Navigate directly to a URL.
        case navigate(URL)

        var id: String {
            switch self {
            case .ask: return "ask"
            case .search: return "search"
            case .navigate: return "navigate"
            }
        }
    }

    /// Ordered routing options for omnibox text, Dia-style: the auto-classified
    /// primary intent is first, followed by the alternatives. The view highlights
    /// the first row by default and lets the user pick another.
    ///
    /// - URL-like text → navigate first.
    /// - A clear question/command → ask first (then search).
    /// - Anything else → search first (then ask).
    static func routes(for raw: String) -> [Route] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        let search = Route.search(googleSearch(text))
        let ask = Route.ask(text)

        if let url = explicitURL(text) {
            return [.navigate(url), search, ask]
        }
        if looksLikeQuestion(text) {
            return [ask, search]
        }
        return [search, ask]
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

    /// Google search URL for a query.
    static func googleSearch(_ query: String) -> URL {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: "https://www.google.com/search?q=\(q)")!
    }

    /// Heuristic intent classifier: does the text read like a question/command for
    /// the AI rather than a search query? Conservative on purpose — ambiguous
    /// keyword strings fall through to search, and the user can still pick "Chat".
    static func looksLikeQuestion(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        if text.hasSuffix("?") || text.hasSuffix("？") { return true }

        let lower = text.lowercased()
        let firstWord = lower.split(whereSeparator: { $0 == " " || $0 == "\u{3000}" }).first.map(String.init) ?? lower
        if englishCues.contains(firstWord) { return true }
        for cue in chineseCues where text.hasPrefix(cue) { return true }
        return false
    }

    /// English question / imperative openers.
    private static let englishCues: Set<String> = [
        "how", "what", "why", "who", "when", "where", "which", "whose", "whom",
        "can", "could", "should", "would", "is", "are", "am", "do", "does", "did",
        "will", "may", "might", "explain", "summarize", "summarise", "write",
        "give", "list", "compare", "tell", "describe", "define", "translate",
        "draft", "generate", "help",
    ]

    /// Chinese question / imperative openers.
    private static let chineseCues: [String] = [
        "怎么", "怎样", "如何", "为什么", "为何", "什么", "哪", "是否", "能否",
        "可以", "解释", "总结", "概括", "写", "给", "列出", "比较", "翻译", "帮我",
        "介绍", "说明",
    ]
}
