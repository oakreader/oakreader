import Foundation
import OakAgent

/// Searches the web using the user's configured search provider.
/// Falls back to DuckDuckGo when no API key is configured.
struct WebSearchTool: AgentTool, Sendable {
    let name = "search_web"
    let description = """
        Search the web for current information on any topic. Returns titles, \
        URLs, and snippets from web pages. Use for non-academic queries: news, \
        documentation, tutorials, product info, current events. For academic \
        papers, use search_academic instead.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description": "Search query",
                ],
                "count": [
                    "type": "string",
                    "description": "Number of results (default: 5, max: 10)",
                ],
                "freshness": [
                    "type": "string",
                    "description": "Recency filter: day, week, month, year",
                ],
            ],
            "required": ["query"],
        ]
    }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let query = input["query"], !query.isEmpty else {
            return .error("Missing required parameter: query")
        }

        let count = min(max(Int(input["count"] ?? "5") ?? 5, 1), 10)
        let freshness = input["freshness"].flatMap { WebSearchFreshness(rawValue: $0) }

        let options = WebSearchOptions(freshness: freshness)
        let provider = WebSearchProviderRegistry.shared.activeProvider()

        let results = await provider.search(query: query, count: count, options: options)

        if results.isEmpty {
            return .success("No web results found for \"\(query)\" (provider: \(provider.displayName)).")
        }

        return .success(formatResults(results, provider: provider.displayName, query: query))
    }

    private func formatResults(_ results: [WebSearchResult], provider: String, query: String) -> String {
        var out = "Results from \(provider) for \"\(query)\":\n"

        for (i, result) in results.enumerated() {
            out += "\n\(i + 1). \(result.title)"
            out += "\n   URL: \(result.url)"
            if !result.snippet.isEmpty {
                out += "\n   \(result.snippet)"
            }
            out += "\n"
        }

        return String(out.prefix(15_000))
    }
}
