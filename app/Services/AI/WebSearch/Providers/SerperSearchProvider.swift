import Foundation

/// Serper provider — Google Search results via API.
/// Endpoint: https://google.serper.dev/search
/// Auth: X-API-KEY header
struct SerperSearchProvider: WebSearchProvider {
    let id = "web-search-serper"
    let displayName = "Serper"
    let requiresAPIKey = true
    let envVar: String? = "SERPER_API_KEY"
    let signupURL: URL? = URL(string: "https://serper.dev/")
    let placeholder = "Enter Serper API key"

    func search(query: String, count: Int, options: WebSearchOptions) async -> [WebSearchResult] {
        guard let apiKey = WebSearchProviderRegistry.resolveAPIKey(for: self) else { return [] }
        guard !query.isEmpty else { return [] }

        guard let url = URL(string: "https://google.serper.dev/search") else { return [] }

        var body: [String: Any] = [
            "q": query,
            "num": min(count, 10),
        ]
        if let country = options.country {
            body["gl"] = country
        }
        if let language = options.language {
            body["hl"] = language
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")
        request.httpBody = jsonData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let organic = json["organic"] as? [[String: Any]]
        else {
            return []
        }

        return organic.prefix(count).compactMap { result in
            guard let title = result["title"] as? String,
                  let link = result["link"] as? String
            else { return nil }
            let snippet = result["snippet"] as? String ?? ""
            return WebSearchResult(
                title: title,
                url: link,
                snippet: snippet,
                source: displayName
            )
        }
    }
}
