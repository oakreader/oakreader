import Foundation
import OakAgent

// MARK: - Academic Search Tool

/// Searches academic papers across multiple providers concurrently:
/// Semantic Scholar, OpenAlex, CrossRef, arXiv, and PubMed.
struct AcademicSearchTool: AgentTool, Sendable {
    let name = "search_academic"
    let description = """
        Search academic papers on the web across Semantic Scholar, OpenAlex, \
        CrossRef, arXiv, and PubMed. Find papers by topic, author, or keywords. \
        Returns titles, authors, years, abstracts, citation counts, DOIs, and \
        source databases. Useful for discovering papers not yet in the library.
        """

    private let providers: [any AcademicSearchProvider] = [
        SemanticScholarProvider(),
        OpenAlexProvider(),
        CrossRefSearchProvider(),
        ArXivProvider(),
        PubMedProvider(),
    ]

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description":
                        "Search query — topic, keywords, paper title, or author name",
                ],
                "max_results": [
                    "type": "string",
                    "description": "Maximum results (default: 10, max: 20)",
                ],
                "year": [
                    "type": "string",
                    "description":
                        "Filter by year or range (e.g., \"2024\" or \"2020-2024\")",
                ],
            ],
            "required": ["query"],
        ]
    }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let query = input["query"], !query.isEmpty else {
            return .error("Missing required parameter: query")
        }
        let limit = min(Int(input["max_results"] ?? "10") ?? 10, 20)
        let year = input["year"]

        Log.info(Log.search, "Academic search: \"\(query)\" (limit=\(limit), year=\(year ?? "any"))")

        // Fan out to all providers concurrently
        let allResults = await withTaskGroup(
            of: (String, [AcademicPaper]).self
        ) { group in
            for provider in providers {
                group.addTask {
                    let papers = await provider.search(query: query, limit: 5, year: year)
                    return (provider.providerName, papers)
                }
            }
            var collected: [(String, [AcademicPaper])] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        // Log which providers responded
        let respondedProviders = allResults.filter { !$0.1.isEmpty }.map(\.0)
        let failedProviders = allResults.filter { $0.1.isEmpty }.map(\.0)
        if !failedProviders.isEmpty {
            Log.warning(
                Log.search,
                "Providers returned no results: \(failedProviders.joined(separator: ", "))"
            )
        }

        // Deduplicate across providers
        let deduplicated = AcademicPaperDeduplicator.deduplicate(allResults)

        if deduplicated.isEmpty {
            return .success("No academic papers found for \"\(query)\".")
        }

        // Rank and take top results
        let currentYear = Calendar.current.component(.year, from: Date())
        let ranked = AcademicPaperRanker.rank(deduplicated, limit: limit, currentYear: currentYear)

        Log.info(
            Log.search,
            "Academic search returned \(ranked.count) papers from \(respondedProviders.count)/\(providers.count) providers"
        )

        return .success(formatResults(ranked, query: query, respondedProviders: respondedProviders))
    }

    // MARK: Private

    private func formatResults(
        _ papers: [AcademicPaper],
        query: String,
        respondedProviders: [String]
    ) -> String {
        var out = "Found \(papers.count) papers for \"\(query)\""
        out += " (sources: \(respondedProviders.joined(separator: ", "))):\n"

        for (i, paper) in papers.enumerated() {
            out += "\n\(i + 1). \(paper.title)"
            if !paper.authors.isEmpty { out += "\n   Authors: \(paper.authors)" }
            if let y = paper.year { out += "\n   Year: \(y)" }
            if let c = paper.citationCount { out += " | Citations: \(c)" }
            if let v = paper.venue { out += "\n   Venue: \(v)" }
            if let d = paper.doi { out += "\n   DOI: \(d)" }
            if let a = paper.arxivId { out += "\n   arXiv: \(a)" }
            if let u = paper.url { out += "\n   URL: \(u)" }
            out += "\n   Source: \(paper.source)"
            if let abs = paper.abstract {
                out += "\n   Abstract: \(String(abs.prefix(250)))"
                if abs.count > 250 { out += "..." }
            }
            out += "\n"
        }

        return String(out.prefix(30_000))
    }
}
