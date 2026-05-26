import Foundation

/// Tavily Search API provider — AI-optimized search results.
/// Endpoint: https://api.tavily.com/search
/// Auth: api_key field in JSON body
struct TavilySearchProvider: WebSearchProvider {
    let id = "web-search-tavily"
    let displayName = "Tavily"
    let requiresAPIKey = true
    let envVar: String? = "TAVILY_API_KEY"
    let signupURL: URL? = URL(string: "https://tavily.com/")
    let placeholder = "tvly-..."

    func search(query: String, count: Int, options: WebSearchOptions) async -> [WebSearchResult] {
        guard let apiKey = WebSearchProviderRegistry.resolveAPIKey(for: self) else { return [] }
        guard !query.isEmpty else { return [] }

        guard let url = URL(string: "https://api.tavily.com/search") else { return [] }

        var body: [String: Any] = [
            "api_key": apiKey,
            "query": query,
            "max_results": min(count, 10),
            "search_depth": "basic",
        ]
        if options.freshness != nil {
            body["search_depth"] = "advanced"
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else {
            return []
        }

        return results.prefix(count).compactMap { result in
            guard let title = result["title"] as? String,
                  let resultURL = result["url"] as? String
            else { return nil }
            let snippet = result["content"] as? String ?? ""
            return WebSearchResult(
                title: title,
                url: resultURL,
                snippet: snippet,
                source: displayName
            )
        }
    }
}
