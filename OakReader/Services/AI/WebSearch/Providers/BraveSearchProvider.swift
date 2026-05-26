import Foundation

/// Brave Search API provider.
/// Endpoint: https://api.search.brave.com/res/v1/web/search
/// Auth: X-Subscription-Token header
struct BraveSearchProvider: WebSearchProvider {
    let id = "web-search-brave"
    let displayName = "Brave Search"
    let requiresAPIKey = true
    let envVar: String? = "BRAVE_API_KEY"
    let signupURL: URL? = URL(string: "https://brave.com/search/api/")
    let placeholder = "BSA..."

    func search(query: String, count: Int, options: WebSearchOptions) async -> [WebSearchResult] {
        guard let apiKey = WebSearchProviderRegistry.resolveAPIKey(for: self) else { return [] }
        guard !query.isEmpty else { return [] }

        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(min(count, 20))),
        ]
        if let country = options.country {
            items.append(URLQueryItem(name: "country", value: country))
        }
        if let language = options.language {
            items.append(URLQueryItem(name: "search_lang", value: language))
        }
        if let freshness = options.freshness {
            let value: String
            switch freshness {
            case .day: value = "pd"
            case .week: value = "pw"
            case .month: value = "pm"
            case .year: value = "py"
            }
            items.append(URLQueryItem(name: "freshness", value: value))
        }
        components.queryItems = items

        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]]
        else {
            return []
        }

        return results.prefix(count).compactMap { result in
            guard let title = result["title"] as? String,
                  let resultURL = result["url"] as? String
            else { return nil }
            let snippet = result["description"] as? String ?? ""
            return WebSearchResult(
                title: title,
                url: resultURL,
                snippet: snippet,
                source: displayName
            )
        }
    }
}
