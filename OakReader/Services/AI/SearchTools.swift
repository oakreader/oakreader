import Foundation
import GRDB
import OakAgent

// MARK: - Search Library Tool

/// Searches across all items in the user's library using FTS5 + targeted SQL queries.
/// Performance: sub-10ms for 10K items (FTS5 path), ~50ms worst case (LIKE fallback).
struct SearchLibraryTool: AgentTool, Sendable {
    let name = "search_library"
    let description = """
        Search across all items in the user's library by title, author, abstract, \
        DOI, journal, or tags. Returns matching items with metadata. Use this to \
        find relevant papers or documents before reading them with read_library_item.
        """
    let dbQueue: DatabaseQueue

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description":
                        "Search text — matches title, author, abstract, DOI, journal, and tags"
                ],
                "max_results": [
                    "type": "string",
                    "description": "Maximum results to return (default: 10)"
                ]
            ],
            "required": ["query"]
        ]
    }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let query = input["query"], !query.isEmpty else {
            return .error("Missing required parameter: query")
        }
        let limit = min(Int(input["max_results"] ?? "10") ?? 10, 50)

        // Tokenize — keep DOI-style strings intact
        let words: [String]
        if query.hasPrefix("10.") || query.contains("doi.org/") {
            words = [query.lowercased()]
        } else {
            words = query.lowercased()
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
        }

        guard !words.isEmpty else {
            return .error("Search query is empty")
        }

        do {
            let results = try await dbQueue.read { db -> [SearchResultItem] in
                // Phase 1: Collect matching item IDs from multiple indexed sources
                var matchingIds = Set<String>()

                // 1a. FTS5 on title + author (sub-ms, uses inverted index)
                let ftsQuery = Self.buildFTSQuery(words: words)
                if !ftsQuery.isEmpty {
                    let ftsSQL = """
                        SELECT i.id FROM items i
                        JOIN items_fts ON items_fts.rowid = i.rowid
                        WHERE items_fts MATCH ?
                        """
                    for row in try Row.fetchAll(db, sql: ftsSQL, arguments: [ftsQuery]) {
                        matchingIds.insert(row["id"] as String)
                    }
                }

                // 1b. Abstract search — all words must appear (uses extracted column)
                if words.count <= 5 {
                    let absConditions = words.map { _ in "c.abstract LIKE ?" }.joined(separator: " AND ")
                    let absSQL = """
                        SELECT c.item_id FROM citations c
                        WHERE c.abstract IS NOT NULL AND (\(absConditions))
                        """
                    let absArgs = words.map { "%\($0)%" }
                    for row in try Row.fetchAll(db, sql: absSQL, arguments: StatementArguments(absArgs)) {
                        matchingIds.insert(row["item_id"] as String)
                    }
                }

                // 1c. DOI exact/partial match (indexed column)
                let fullPattern = "%\(query)%"
                for row in try Row.fetchAll(db, sql: """
                    SELECT item_id FROM citations WHERE doi LIKE ?
                    """, arguments: [fullPattern]) {
                    matchingIds.insert(row["item_id"] as String)
                }

                // 1d. Journal name search (indexed column)
                for row in try Row.fetchAll(db, sql: """
                    SELECT item_id FROM citations WHERE container_title LIKE ?
                    """, arguments: [fullPattern]) {
                    matchingIds.insert(row["item_id"] as String)
                }

                // 1e. Tag search — any word matches any tag name
                let tagConditions = words.map { _ in "po.name LIKE ?" }.joined(separator: " OR ")
                let tagArgs = words.map { "%\($0)%" }
                for row in try Row.fetchAll(db, sql: """
                    SELECT DISTINCT ipv.item_id FROM item_property_values ipv
                    JOIN property_options po ON po.id = ipv.option_id
                    WHERE \(tagConditions)
                    """, arguments: StatementArguments(tagArgs)) {
                    matchingIds.insert(row["item_id"] as String)
                }

                if matchingIds.isEmpty { return [] }

                // Phase 2: Fetch full details for matching items (frecency-ranked)
                let ids = Array(matchingIds)
                let placeholders = ids.map { _ in "?" }.joined(separator: ",")
                let detailSQL = """
                    SELECT i.id, i.title, i.author, i.storage_key, i.cite_key,
                           i.last_opened_at,
                           a.attachment_type, a.page_count, a.file_name,
                           a.storage_key AS att_storage_key,
                           c.csl_type, c.year, c.doi, c.container_title, c.abstract,
                           (SELECT GROUP_CONCAT(po.name, ', ')
                            FROM item_property_values ipv
                            JOIN property_options po ON po.id = ipv.option_id
                            JOIN properties p ON p.id = ipv.property_id AND p.name = 'Tags'
                            WHERE ipv.item_id = i.id) AS tag_names
                    FROM items i
                    LEFT JOIN attachments a ON a.item_id = i.id AND a.is_primary = 1
                    LEFT JOIN citations c ON c.item_id = i.id
                    WHERE i.id IN (\(placeholders))
                    ORDER BY
                        CASE WHEN i.last_opened_at IS NOT NULL THEN 0 ELSE 1 END,
                        i.last_opened_at DESC,
                        i.created_at DESC
                    LIMIT ?
                    """
                let detailArgs = StatementArguments(ids + ["\(limit)"])
                let rows = try Row.fetchAll(db, sql: detailSQL, arguments: detailArgs)

                return rows.map { row in
                    let tagNames: String? = row["tag_names"]
                    let tags = tagNames?
                        .components(separatedBy: ", ")
                        .filter { !$0.isEmpty } ?? []

                    return SearchResultItem(
                        title: row["title"],
                        author: row["author"],
                        citeKey: row["cite_key"],
                        attachmentType: row["attachment_type"],
                        pageCount: row["page_count"],
                        cslType: row["csl_type"],
                        year: row["year"],
                        doi: row["doi"],
                        journal: row["container_title"],
                        abstract: row["abstract"],
                        tags: tags
                    )
                }
            }

            if results.isEmpty {
                return .success("No items found matching \"\(query)\" in the library.")
            }
            return .success(formatResults(results, query: query))
        } catch {
            return .error("Search failed: \(error.localizedDescription)")
        }
    }

    // MARK: Private

    /// Build a safe FTS5 query string. Each word is quoted to prevent syntax errors.
    /// Result: `"attention" "mechanism"` (implicit AND).
    private static func buildFTSQuery(words: [String]) -> String {
        words.compactMap { word in
            let clean = word.filter { $0.isLetter || $0.isNumber }
            return clean.isEmpty ? nil : "\"\(clean)\""
        }.joined(separator: " ")
    }

    private func formatResults(_ results: [SearchResultItem], query: String) -> String {
        var out = "Found \(results.count) item(s) matching \"\(query)\":\n"

        for (i, r) in results.enumerated() {
            out += "\n\(i + 1). "
            if let ck = r.citeKey { out += "[\(ck)] " }
            out += r.title
            if !r.author.isEmpty { out += "\n   Authors: \(r.author)" }

            var meta: [String] = []
            if let t = r.cslType { meta.append(t) }
            if let y = r.year { meta.append("Year: \(y)") }
            if let at = r.attachmentType, let pc = r.pageCount {
                meta.append("\(at), \(pc) pages")
            }
            if !meta.isEmpty { out += "\n   \(meta.joined(separator: " | "))" }

            if let j = r.journal { out += "\n   Journal: \(j)" }
            if let d = r.doi { out += "\n   DOI: \(d)" }
            if !r.tags.isEmpty { out += "\n   Tags: \(r.tags.joined(separator: ", "))" }
            if let abs = r.abstract {
                let truncated = String(abs.prefix(200))
                out += "\n   Abstract: \(truncated)"
                if abs.count > 200 { out += "..." }
            }
            out += "\n"
        }

        out += "\nUse read_library_item with a cite_key to read any of these documents."
        return String(out.prefix(30_000))
    }

    private struct SearchResultItem: Sendable {
        let title: String
        let author: String
        let citeKey: String?
        let attachmentType: String?
        let pageCount: Int?
        let cslType: String?
        let year: Int?
        let doi: String?
        let journal: String?
        let abstract: String?
        let tags: [String]
    }
}

// MARK: - Read Library Item Tool

/// Reads the content of any item in the library by its cite key or title.
struct ReadLibraryItemTool: AgentTool, Sendable {
    let name = "read_library_item"
    let description = """
        Read the content of any item in the library by its cite key. Use \
        search_library first to find items, then read them with this tool. \
        For PDFs, you can specify page numbers.
        """
    let dbQueue: DatabaseQueue

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "cite_key": [
                    "type": "string",
                    "description":
                        "Cite key of the item (e.g., \"Smith2024\"). From search_library results."
                ],
                "title": [
                    "type": "string",
                    "description":
                        "Title of the item (alternative to cite_key, partial match)."
                ],
                "pages": [
                    "type": "string",
                    "description":
                        "Page range for PDFs (e.g., \"1-5\", \"3,7,12\"). Omit to read all."
                ]
            ]
        ]
    }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        let citeKey = input["cite_key"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = input["title"]?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (citeKey != nil && !citeKey!.isEmpty) || (title != nil && !title!.isEmpty) else {
            return .error("Provide either cite_key or title to identify the item.")
        }

        let info: ItemFileInfo?
        do {
            info = try await dbQueue.read { db -> ItemFileInfo? in
                let row: Row?
                if let ck = citeKey, !ck.isEmpty {
                    row = try Row.fetchOne(db, sql: """
                        SELECT i.storage_key, a.storage_key AS att_key, a.file_name,
                               a.attachment_type, a.page_count
                        FROM items i
                        JOIN attachments a ON a.item_id = i.id AND a.is_primary = 1
                        WHERE i.cite_key = ?
                        """, arguments: [ck])
                } else {
                    let pattern = "%\(title!)%"
                    row = try Row.fetchOne(db, sql: """
                        SELECT i.storage_key, a.storage_key AS att_key, a.file_name,
                               a.attachment_type, a.page_count
                        FROM items i
                        JOIN attachments a ON a.item_id = i.id AND a.is_primary = 1
                        WHERE i.title LIKE ? COLLATE NOCASE
                        ORDER BY i.created_at DESC
                        """, arguments: [pattern])
                }

                guard let r = row else { return nil }
                return ItemFileInfo(
                    itemStorageKey: r["storage_key"],
                    attStorageKey: r["att_key"],
                    fileName: r["file_name"],
                    attachmentType: r["attachment_type"],
                    pageCount: r["page_count"]
                )
            }
        } catch {
            return .error("Database error: \(error.localizedDescription)")
        }

        guard let info else {
            let identifier = citeKey ?? title ?? "unknown"
            return .error(
                "No item found for \"\(identifier)\". Use search_library to find items first."
            )
        }

        let fileURL = CatalogDatabase.attachmentFileURL(
            itemStorageKey: info.itemStorageKey,
            attachmentStorageKey: info.attStorageKey,
            fileName: info.fileName
        )

        // Delegate to ReadDocumentTool for the actual file reading
        let reader = ReadDocumentTool(
            filePath: fileURL.path,
            documentType: info.attachmentType,
            pageCount: info.pageCount
        )
        return try await reader.execute(input: ["pages": input["pages"] ?? ""], context: context)
    }

    private struct ItemFileInfo {
        let itemStorageKey: String
        let attStorageKey: String
        let fileName: String
        let attachmentType: String
        let pageCount: Int
    }
}

// MARK: - Academic Search Tool

/// Searches academic papers on the web via Semantic Scholar.
struct AcademicSearchTool: AgentTool, Sendable {
    let name = "search_academic"
    let description = """
        Search academic papers on the web using Semantic Scholar. Find papers by \
        topic, author, or keywords. Returns titles, authors, years, abstracts, \
        citation counts, and DOIs. Useful for discovering papers not yet in the library.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string",
                    "description":
                        "Search query — topic, keywords, paper title, or author name"
                ],
                "max_results": [
                    "type": "string",
                    "description": "Maximum results (default: 5, max: 20)"
                ],
                "year": [
                    "type": "string",
                    "description":
                        "Filter by year or range (e.g., \"2024\" or \"2020-2024\")"
                ]
            ],
            "required": ["query"]
        ]
    }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let query = input["query"], !query.isEmpty else {
            return .error("Missing required parameter: query")
        }
        let limit = min(Int(input["max_results"] ?? "5") ?? 5, 20)

        var components = URLComponents(
            string: "https://api.semanticscholar.org/graph/v1/paper/search"
        )!
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(
                name: "fields",
                value: "title,authors,year,abstract,citationCount,externalIds,url"
            )
        ]
        if let year = input["year"], !year.isEmpty {
            items.append(URLQueryItem(name: "year", value: year))
        }
        components.queryItems = items

        guard let url = components.url else {
            return .error("Failed to build search URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            return .error("Search cancelled")
        } catch {
            return .error("Network error: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            return .error("Invalid response from Semantic Scholar")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 429 {
                return .error("Rate limited by Semantic Scholar. Wait a moment and retry.")
            }
            return .error("Semantic Scholar returned HTTP \(http.statusCode)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let papers = json["data"] as? [[String: Any]]
        else {
            return .error("Failed to parse Semantic Scholar response")
        }

        if papers.isEmpty {
            return .success("No academic papers found for \"\(query)\".")
        }

        let total = json["total"] as? Int ?? papers.count
        var out = "Found \(total) papers (showing \(papers.count)):\n"

        for (i, paper) in papers.enumerated() {
            let title = paper["title"] as? String ?? "Unknown"
            let year = paper["year"] as? Int
            let abstract = paper["abstract"] as? String
            let citations = paper["citationCount"] as? Int
            let paperURL = paper["url"] as? String
            let extIds = paper["externalIds"] as? [String: Any]
            let doi = extIds?["DOI"] as? String
            let arxiv = extIds?["ArXiv"] as? String

            let authors: String
            if let list = paper["authors"] as? [[String: Any]] {
                authors = list.compactMap { $0["name"] as? String }.joined(separator: ", ")
            } else {
                authors = "Unknown"
            }

            out += "\n\(i + 1). \(title)"
            out += "\n   Authors: \(authors)"
            if let y = year { out += "\n   Year: \(y)" }
            if let c = citations { out += " | Citations: \(c)" }
            if let d = doi { out += "\n   DOI: \(d)" }
            if let a = arxiv { out += "\n   ArXiv: \(a)" }
            if let u = paperURL { out += "\n   URL: \(u)" }
            if let abs = abstract {
                out += "\n   Abstract: \(String(abs.prefix(250)))"
                if abs.count > 250 { out += "..." }
            }
            out += "\n"
        }

        return .success(String(out.prefix(30_000)))
    }
}
