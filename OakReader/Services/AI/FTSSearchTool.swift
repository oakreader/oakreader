import Foundation
import GRDB
import OakAgent

/// Searches the full text of the user's library using FTS5 BM25 keyword ranking.
/// Use to find documents whose *content* mentions specific terms (not just titles).
/// The chat agent drives retrieval: issue a query, read the results, and refine the
/// query or call again as needed.
struct FTSSearchTool: AgentTool, Sendable {
    let name = "search_content"
    let description = """
        Full-text search across the content of the user's library documents (BM25 \
        keyword ranking over indexed page/section text). Use this to find passages \
        that mention specific terms, phrases, or topics inside a document's body — \
        not just the title. Returns the top matching passages, each with a relevance \
        score, a snippet around the match, and a page reference, so you can then read \
        the most promising ones with the oak tool (oak items read <citeKey> --pages). \
        If the first query returns too little or too much, refine the terms and search \
        again. Optionally pass content_type to restrict the search to one kind of \
        document. For exact lookups by author, title, or DOI, use oak search instead.
        """
    let service: FTSIndexService

    /// When set, retrieval is physically restricted to the members of this
    /// collection (catalog id / UUID string). This is how GROUNDED mode enforces
    /// scoping — the model cannot widen it because the collection is not a tool
    /// parameter. `nil` means search the whole library.
    var scopeCollectionId: String?

    /// One retrieved passage, in structured form. Used by the research subagent to
    /// build a deterministic source list from what was actually retrieved.
    struct CitedPassage: Sendable, Hashable {
        let citeKey: String?
        let title: String
        let author: String?
        let page: Int?      // 1-based, nil for abstract/whole-doc chunks
        let snippet: String
    }

    /// Optional sink invoked with the structured results of each successful search.
    /// `nil` for the normal chat agent; set by `ResearchTool` to log retrievals.
    var onResults: (@Sendable ([CitedPassage]) -> Void)?

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description":
                        "Keywords or a short natural-language description of the topic to find"
                ],
                "max_results": [
                    "type": "string",
                    "description": "Maximum passages to return (default: 10, max 50)"
                ],
                "content_type": [
                    "type": "string",
                    "description":
                        "Optional scope filter: only search documents of this type. One of: pdf, html, markdown, video.",
                    "enum": ["pdf", "html", "markdown", "video"]
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

        // Optional scope: resolve content_type → the set of item IDs to search within.
        var contentTypeIds: [String]?
        if let contentType = input["content_type"], !contentType.isEmpty {
            do {
                let ids = try await service.catalogDBQueue.read { db in
                    try String.fetchAll(db, sql: """
                        SELECT DISTINCT i.id FROM items i
                        JOIN attachments a ON a.item_id = i.id AND a.is_primary = 1
                        WHERE a.content_type = ?
                        """, arguments: [contentType])
                }
                if ids.isEmpty {
                    return .success("No \(contentType) documents in the library to search.")
                }
                contentTypeIds = ids
            } catch {
                return .error("Failed to resolve content_type filter: \(error.localizedDescription)")
            }
        }

        // GROUNDED scope: restrict to the active collection's members. Enforced by
        // the host (not a tool parameter), so the model cannot search outside it.
        var collectionIds: [String]?
        if let collectionId = scopeCollectionId, !collectionId.isEmpty {
            do {
                let ids = try await service.catalogDBQueue.read { db in
                    try String.fetchAll(db, sql:
                        "SELECT item_id FROM collection_items WHERE collection_id = ?",
                        arguments: [collectionId])
                }
                if ids.isEmpty {
                    return .success("The active collection has no documents to search.")
                }
                collectionIds = ids
            } catch {
                return .error("Failed to resolve collection scope: \(error.localizedDescription)")
            }
        }

        // Combine the two scopes by intersection (each is a whitelist of item ids).
        let scopeItemIds: [String]?
        switch (contentTypeIds, collectionIds) {
        case (nil, nil): scopeItemIds = nil
        case (let ct?, nil): scopeItemIds = ct
        case (nil, let coll?): scopeItemIds = coll
        case (let ct?, let coll?):
            let inter = Set(ct).intersection(coll)
            if inter.isEmpty {
                return .success("No matching documents in this scope (the content_type filter excludes every document in the collection).")
            }
            scopeItemIds = Array(inter)
        }

        // Passages mode: return distinct top-ranked excerpts (not collapsed per item).
        let results = await service.search(query: query, maxResults: limit, itemIds: scopeItemIds, groupByItem: false)

        if results.isEmpty {
            let scope = scopeCollectionId != nil ? "the active collection" : "the library"
            return .success("No documents matching \"\(query)\" were found in \(scope).")
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

        // Report structured passages to any observer (e.g. the research subagent).
        if let onResults {
            onResults(results.map { r in
                let meta = metadata[r.itemId]
                return CitedPassage(
                    citeKey: meta?.citeKey,
                    title: meta?.title ?? "Unknown",
                    author: meta?.author,
                    page: r.pageStart.map { $0 + 1 },
                    snippet: r.excerpt
                )
            })
        }

        return .success(formatResults(results, metadata: metadata, query: query))
    }

    // MARK: - Private

    private func formatResults(
        _ results: [FTSIndexService.SearchResult],
        metadata: [String: ItemMeta],
        query: String
    ) -> String {
        var out = "Found \(results.count) matching passage(s) for \"\(query)\":\n"

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
