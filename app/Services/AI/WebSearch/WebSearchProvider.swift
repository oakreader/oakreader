import Foundation

// MARK: - Web Search Provider Protocol

protocol WebSearchProvider: Sendable {
    /// Unique identifier used as Keychain key prefix (e.g. "web-search-brave").
    var id: String { get }

    /// Human-readable name shown in settings UI.
    var displayName: String { get }

    /// Whether this provider requires an API key to function.
    var requiresAPIKey: Bool { get }

    /// Environment variable name for fallback credential resolution (e.g. "BRAVE_API_KEY").
    var envVar: String? { get }

    /// URL to the developer portal for API key signup.
    var signupURL: URL? { get }

    /// Placeholder text shown in the API key input field.
    var placeholder: String { get }

    /// Search the web. Returns `[]` on any failure (never throws).
    func search(query: String, count: Int, options: WebSearchOptions) async -> [WebSearchResult]
}

// MARK: - Search Options

struct WebSearchOptions: Sendable {
    var freshness: WebSearchFreshness?
    var country: String?
    var language: String?

    init(freshness: WebSearchFreshness? = nil, country: String? = nil, language: String? = nil) {
        self.freshness = freshness
        self.country = country
        self.language = language
    }
}

enum WebSearchFreshness: String, Sendable {
    case day, week, month, year
}

// MARK: - Search Result

struct WebSearchResult: Sendable {
    var title: String
    var url: String
    var snippet: String
    var source: String
}
