import Foundation

/// A search engine used by the browser chrome — the new-tab omnibox and the live
/// web address bar. Mirrors the "default search engine" control every browser
/// ships, so a query that isn't a URL gets handed to the user's chosen engine
/// rather than a hardcoded one.
enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case google
    case bing
    case duckDuckGo
    case brave
    case baidu
    case ecosia
    case startpage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .duckDuckGo: return "DuckDuckGo"
        case .brave: return "Brave"
        case .baidu: return "Baidu"
        case .ecosia: return "Ecosia"
        case .startpage: return "Startpage"
        }
    }

    /// URL prefix the percent-encoded query is appended to.
    private var queryPrefix: String {
        switch self {
        case .google: return "https://www.google.com/search?q="
        case .bing: return "https://www.bing.com/search?q="
        case .duckDuckGo: return "https://duckduckgo.com/?q="
        case .brave: return "https://search.brave.com/search?q="
        case .baidu: return "https://www.baidu.com/s?wd="
        case .ecosia: return "https://www.ecosia.org/search?q="
        case .startpage: return "https://www.startpage.com/sp/search?query="
        }
    }

    /// Image asset for the engine's mark, if one ships in the asset catalog.
    /// Engines without a bundled mark fall back to a generic search glyph.
    var iconAsset: String? {
        switch self {
        case .google: return "SearchEngineGoogle"
        default: return nil
        }
    }

    /// Search URL for a query.
    func searchURL(for query: String) -> URL {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: "\(queryPrefix)\(q)") ?? URL(string: queryPrefix)!
    }
}
