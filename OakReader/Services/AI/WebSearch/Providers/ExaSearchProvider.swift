import Foundation

/// Exa neural search provider.
/// Endpoint: https://api.exa.ai/search
/// Auth: Authorization Bearer header
struct ExaSearchProvider: WebSearchProvider {
    let id = "web-search-exa"
    let displayName = "Exa"
    let requiresAPIKey = true
    let envVar: String? = "EXA_API_KEY"
    let signupURL: URL? = URL(string: "https://exa.ai/")
    let placeholder = "exa-..."

    func search(query: String, count: Int, options: WebSearchOptions) async -> [WebSearchResult] {
        guard let apiKey = WebSearchProviderRegistry.resolveAPIKey(for: self) else { return [] }
        guard !query.isEmpty else { return [] }

        guard let url = URL(string: "https://api.exa.ai/search") else { return [] }

        var body: [String: Any] = [
            "query": query,
            "numResults": min(count, 10),
            "type": "auto",
            "useAutoprompt": true,
        ]
        if let freshness = options.freshness {
            let calendar = Calendar.current
            let now = Date()
            let startDate: Date?
            switch freshness {
            case .day: startDate = calendar.date(byAdding: .day, value: -1, to: now)
            case .week: startDate = calendar.date(byAdding: .weekOfYear, value: -1, to: now)
            case .month: startDate = calendar.date(byAdding: .month, value: -1, to: now)
            case .year: startDate = calendar.date(byAdding: .year, value: -1, to: now)
            }
            if let startDate {
                let formatter = ISO8601DateFormatter()
                body["startPublishedDate"] = formatter.string(from: startDate)
            }
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
            let snippet = result["text"] as? String
                ?? (result["highlights"] as? [String])?.first
                ?? ""
            return WebSearchResult(
                title: title,
                url: resultURL,
                snippet: String(snippet.prefix(300)),
                source: displayName
            )
        }
    }
}
