import Foundation
import GRDB
import OakAgent

/// Searches the full text of the user's library using FTS5 BM25 keyword ranking.
/// Use to find documents whose *content* mentions specific terms (not just titles).
/// The chat agent drives retrieval: issue a query, read the results, and refine the
/// query or call again as needed.
struct SemanticSearchTool: AgentTool, Sendable {
    let name = "search_content"
    let description = """
        Full-text search across the content of the user's library documents (BM25 \
        keyword ranking over indexed page/section text). Use this to find documents \
        that mention specific terms, phrases, or topics inside their body — not just \
        the title. If the first query is too broad or too narrow, refine the terms \
        and search again. For exact lookups by author, title, or DOI, use the oak \
        tool instead (oak search <query>). \
        Returns matching items with relevance scores, excerpts, and page references.
        """
    let service: SemanticIndexService

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description":
                        "Natural language description of the topic or concept to search for"
                ],
                "max_results": [
                    "type": "string",
                    "description": "Maximum results to return (default: 10)"
                ]
            ],
            "required": ["query"]
        ]
    }

    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolOutput {
        guard let query = input["query"], !query.isEmpty else {
            return .error("Missing required parameter: query")
        }
        let limit = min(Int(input["max_results"] ?? "10") ?? 10, 50)

        let results = await service.search(query: query, maxResults: limit)

        if results.isEmpty {
            return .success("No documents matching \"\(query)\" were found in the library.")
        }

        // Enrich results with item metadata from catalog.db
        let itemIds = results.map(\.itemId)
        let metadata: [String: ItemMeta]
        do {
            metadata = try await service.catalogDBQueue.read { db -> [String: ItemMeta] in
                let placeholders = itemIds.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT i.id, i.title, i.author, i.cite_key,
                           a.content_type, a.page_count,
                           c.year, c.doi, c.container_title
                    FROM items i
                    LEFT JOIN attachments a ON a.item_id = i.id AND a.is_primary = 1
                    LEFT JOIN citations c ON c.item_id = i.id
                    WHERE i.id IN (\(placeholders))
                    """, arguments: StatementArguments(itemIds))

                var map: [String: ItemMeta] = [:]
                for row in rows {
                    let id: String = row["id"]
                    map[id] = ItemMeta(
                        title: row["title"],
                        author: row["author"],
                        citeKey: row["cite_key"],
                        contentType: row["content_type"],
                        pageCount: row["page_count"],
                        year: row["year"],
                        doi: row["doi"],
                        journal: row["container_title"]
                    )
                }
                return map
            }
        } catch {
            return .error("Failed to fetch item metadata: \(error.localizedDescription)")
        }

        return .success(formatResults(results, metadata: metadata, query: query))
    }

    // MARK: - Private

    private func formatResults(
        _ results: [SemanticIndexService.SearchResult],
        metadata: [String: ItemMeta],
        query: String
    ) -> String {
        var out = "Found \(results.count) matching document(s) for \"\(query)\":\n"

        for (i, r) in results.enumerated() {
            let meta = metadata[r.itemId]
            out += "\n\(i + 1). "
            if let ck = meta?.citeKey { out += "[\(ck)] " }
            out += meta?.title ?? "Unknown"

            if let author = meta?.author, !author.isEmpty {
                out += "\n   Authors: \(author)"
            }

            var info: [String] = []
            if let y = meta?.year { info.append("Year: \(y)") }
            if let at = meta?.contentType, let pc = meta?.pageCount {
                info.append("\(at), \(pc) pages")
            }
            info.append("Score: \(String(format: "%.2f", r.score))")
            out += "\n   \(info.joined(separator: " | "))"

            if let j = meta?.journal { out += "\n   Journal: \(j)" }
            if let d = meta?.doi { out += "\n   DOI: \(d)" }

            // Page reference
            if let ps = r.pageStart {
                out += "\n   Best match: \(r.chunkType) (page \(ps + 1))"
            } else if r.chunkType == "abstract" {
                out += "\n   Best match: abstract"
            }

            // Excerpt
            if !r.excerpt.isEmpty {
                let truncated = String(r.excerpt.prefix(200))
                out += "\n   Excerpt: \(truncated)"
                if r.excerpt.count > 200 { out += "..." }
            }

            out += "\n"
        }

        out += "\nUse the oak tool to read any of these documents: oak items read <citeKey> --pages 1-5"
        return String(out.prefix(30_000))
    }

    private struct ItemMeta {
        let title: String
        let author: String
        let citeKey: String?
        let contentType: String?
        let pageCount: Int?
        let year: Int?
        let doi: String?
        let journal: String?
    }
}
