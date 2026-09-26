import Foundation

// MARK: - Common Model

struct AcademicPaper: Sendable {
    var title: String
    var authors: String
    var year: Int?
    var abstract: String?
    var doi: String?
    var arxivId: String?
    var url: String?
    var citationCount: Int?
    var source: String        // e.g. "Semantic Scholar", "OpenAlex, CrossRef"
    var venue: String?
}

// MARK: - Provider Protocol

protocol AcademicSearchProvider: Sendable {
    var providerName: String { get }
    /// Returns `[]` on any failure (never throws). Provider handles its own errors.
    func search(query: String, limit: Int, year: String?) async -> [AcademicPaper]
}

// MARK: - Semantic Scholar

struct SemanticScholarProvider: AcademicSearchProvider {
    let providerName = "Semantic Scholar"

    func search(query: String, limit: Int, year: String?) async -> [AcademicPaper] {
        var components = URLComponents(string: "https://api.semanticscholar.org/graph/v1/paper/search")!
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(
                name: "fields",
                value: "title,authors,year,abstract,citationCount,externalIds,url,venue"
            ),
        ]
        if let year, !year.isEmpty {
            items.append(URLQueryItem(name: "year", value: year))
        }
        components.queryItems = items

        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let papers = json["data"] as? [[String: Any]]
        else {
            Log.warning(Log.search, "Semantic Scholar request failed")
            return []
        }

        return papers.compactMap { paper in
            guard let title = paper["title"] as? String, !title.isEmpty else { return nil }
            let extIds = paper["externalIds"] as? [String: Any]
            let authors: String
            if let list = paper["authors"] as? [[String: Any]] {
                authors = list.compactMap { $0["name"] as? String }.joined(separator: ", ")
            } else {
                authors = ""
            }
            return AcademicPaper(
                title: title,
                authors: authors,
                year: paper["year"] as? Int,
                abstract: paper["abstract"] as? String,
                doi: extIds?["DOI"] as? String,
                arxivId: extIds?["ArXiv"] as? String,
                url: paper["url"] as? String,
                citationCount: paper["citationCount"] as? Int,
                source: providerName,
                venue: paper["venue"] as? String
            )
        }
    }
}

// MARK: - OpenAlex

struct OpenAlexProvider: AcademicSearchProvider {
    let providerName = "OpenAlex"

    func search(query: String, limit: Int, year: String?) async -> [AcademicPaper] {
        var components = URLComponents(string: "https://api.openalex.org/works")!
        var items = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "per_page", value: String(limit)),
            URLQueryItem(
                name: "select",
                value: "title,authorships,publication_year,abstract_inverted_index,doi,cited_by_count,primary_location,ids"
            ),
            URLQueryItem(name: "mailto", value: "oakreader@example.com"),
        ]
        if let year, !year.isEmpty {
            // OpenAlex uses filter for year ranges
            if year.contains("-") {
                let parts = year.split(separator: "-")
                if parts.count == 2 {
                    items.append(URLQueryItem(
                        name: "filter",
                        value: "publication_year:\(parts[0])-\(parts[1])"
                    ))
                }
            } else {
                items.append(URLQueryItem(name: "filter", value: "publication_year:\(year)"))
            }
        }
        components.queryItems = items

        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]]
        else {
            Log.warning(Log.search, "OpenAlex request failed")
            return []
        }

        return results.compactMap { work in
            guard let title = work["title"] as? String, !title.isEmpty else { return nil }

            let authors: String
            if let authorships = work["authorships"] as? [[String: Any]] {
                authors = authorships.compactMap { authorship in
                    (authorship["author"] as? [String: Any])?["display_name"] as? String
                }.joined(separator: ", ")
            } else {
                authors = ""
            }

            // Reconstruct abstract from inverted index
            let abstract = Self.reconstructAbstract(
                from: work["abstract_inverted_index"] as? [String: [Int]]
            )

            // Extract DOI — OpenAlex gives full URL like "https://doi.org/10.1234/..."
            var doi: String?
            if let rawDOI = work["doi"] as? String {
                doi = rawDOI
                    .replacingOccurrences(of: "https://doi.org/", with: "")
                    .replacingOccurrences(of: "http://doi.org/", with: "")
            }

            // Venue from primary_location
            let venue: String?
            if let location = work["primary_location"] as? [String: Any],
               let source = location["source"] as? [String: Any] {
                venue = source["display_name"] as? String
            } else {
                venue = nil
            }

            return AcademicPaper(
                title: title,
                authors: authors,
                year: work["publication_year"] as? Int,
                abstract: abstract,
                doi: doi,
                arxivId: nil,
                url: work["doi"] as? String,
                citationCount: work["cited_by_count"] as? Int,
                source: providerName,
                venue: venue
            )
        }
    }

    /// Reconstruct plain-text abstract from OpenAlex inverted index format.
    /// The inverted index maps each word to the list of positions where it appears.
    private static func reconstructAbstract(from invertedIndex: [String: [Int]]?) -> String? {
        guard let invertedIndex, !invertedIndex.isEmpty else { return nil }

        var words: [(Int, String)] = []
        for (word, positions) in invertedIndex {
            for pos in positions {
                words.append((pos, word))
            }
        }
        words.sort { $0.0 < $1.0 }

        let result = words.map(\.1).joined(separator: " ")
        return result.isEmpty ? nil : result
    }
}

// MARK: - CrossRef

struct CrossRefSearchProvider: AcademicSearchProvider {
    let providerName = "CrossRef"

    func search(query: String, limit: Int, year: String?) async -> [AcademicPaper] {
        var components = URLComponents(string: "https://api.crossref.org/works")!
        var items = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "rows", value: String(limit)),
            URLQueryItem(
                name: "select",
                value: "DOI,title,author,published-print,abstract,is-referenced-by-count,container-title,URL"
            ),
        ]
        if let year, !year.isEmpty {
            // CrossRef filter by year range
            if year.contains("-") {
                let parts = year.split(separator: "-")
                if parts.count == 2 {
                    items.append(URLQueryItem(
                        name: "filter",
                        value: "from-pub-date:\(parts[0]),until-pub-date:\(parts[1])"
                    ))
                }
            } else {
                items.append(URLQueryItem(
                    name: "filter",
                    value: "from-pub-date:\(year),until-pub-date:\(year)"
                ))
            }
        }
        components.queryItems = items

        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // CrossRef polite pool requires User-Agent with contact info
        request.setValue(
            "OakReader/1.0 (mailto:oakreader@example.com)",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = json["message"] as? [String: Any],
              let items = message["items"] as? [[String: Any]]
        else {
            Log.warning(Log.search, "CrossRef request failed")
            return []
        }

        return items.compactMap { item in
            // Title is an array in CrossRef
            guard let titles = item["title"] as? [String], let title = titles.first, !title.isEmpty
            else { return nil }

            let authors: String
            if let authorList = item["author"] as? [[String: Any]] {
                authors = authorList.compactMap { author in
                    let given = author["given"] as? String ?? ""
                    let family = author["family"] as? String ?? ""
                    return [given, family].filter { !$0.isEmpty }.joined(separator: " ")
                }.joined(separator: ", ")
            } else {
                authors = ""
            }

            // Extract year from published-print date-parts
            var year: Int?
            if let published = item["published-print"] as? [String: Any],
               let dateParts = published["date-parts"] as? [[Int]],
               let first = dateParts.first, !first.isEmpty {
                year = first[0]
            }

            // Strip HTML tags from abstract if present
            var abstract = item["abstract"] as? String
            if let abs = abstract {
                abstract = abs.replacingOccurrences(
                    of: "<[^>]+>",
                    with: "",
                    options: .regularExpression
                )
            }

            let venue: String?
            if let containers = item["container-title"] as? [String] {
                venue = containers.first
            } else {
                venue = nil
            }

            return AcademicPaper(
                title: title,
                authors: authors,
                year: year,
                abstract: abstract,
                doi: item["DOI"] as? String,
                arxivId: nil,
                url: item["URL"] as? String,
                citationCount: item["is-referenced-by-count"] as? Int,
                source: providerName,
                venue: venue
            )
        }
    }
}

// MARK: - ArXiv

struct ArXivProvider: AcademicSearchProvider {
    let providerName = "arXiv"

    func search(query: String, limit: Int, year: String?) async -> [AcademicPaper] {
        // arXiv API uses Atom XML
        var searchQuery = "all:\(query)"
        // arXiv doesn't have a year filter in the API — approximate with submittedDate if provided
        if let year, !year.isEmpty, !year.contains("-"), let y = Int(year) {
            searchQuery = "all:\(query) AND submittedDate:[\(y)0101 TO \(y)1231]"
        }

        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: searchQuery),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: String(limit)),
            URLQueryItem(name: "sortBy", value: "relevance"),
        ]

        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else {
            Log.warning(Log.search, "arXiv request failed")
            return []
        }

        return parseAtomFeed(data)
    }

    private func parseAtomFeed(_ data: Data) -> [AcademicPaper] {
        guard let doc = try? XMLDocument(data: data, options: []) else { return [] }
        let ns = ["atom": "http://www.w3.org/2005/Atom", "arxiv": "http://arxiv.org/schemas/atom"]

        guard let entries = try? doc.rootElement()?.nodes(forXPath: "//atom:entry") else {
            return []
        }

        return entries.compactMap { node -> AcademicPaper? in
            guard let entry = node as? XMLElement else { return nil }

            let title = textContent(entry, name: "title", namespaces: ns)?
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else { return nil }

            let authors: String
            if let authorElements = try? entry.nodes(forXPath: "atom:author/atom:name") {
                authors = authorElements.compactMap { $0.stringValue }.joined(separator: ", ")
            } else {
                authors = ""
            }

            // Extract year from <published>
            var year: Int?
            if let published = textContent(entry, name: "published", namespaces: ns),
               published.count >= 4 {
                year = Int(published.prefix(4))
            }

            let abstract = textContent(entry, name: "summary", namespaces: ns)?
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Extract arXiv ID from <id> tag (URL like http://arxiv.org/abs/2301.12345v1)
            var arxivId: String?
            var paperURL: String?
            if let idStr = textContent(entry, name: "id", namespaces: ns) {
                paperURL = idStr
                if let range = idStr.range(of: "/abs/") {
                    var rawId = String(idStr[range.upperBound...])
                    // Strip version suffix
                    if let vRange = rawId.range(of: "v\\d+$", options: .regularExpression) {
                        rawId = String(rawId[..<vRange.lowerBound])
                    }
                    arxivId = rawId
                }
            }

            // Extract DOI if present (via <arxiv:doi>)
            let doi: String?
            if let doiElements = try? entry.nodes(forXPath: "arxiv:doi") {
                doi = doiElements.first?.stringValue
            } else {
                doi = nil
            }

            return AcademicPaper(
                title: title,
                authors: authors,
                year: year,
                abstract: abstract,
                doi: doi,
                arxivId: arxivId,
                url: paperURL,
                citationCount: nil,
                source: providerName,
                venue: nil
            )
        }
    }

    private func textContent(
        _ element: XMLElement,
        name: String,
        namespaces ns: [String: String]
    ) -> String? {
        let nodes = try? element.nodes(forXPath: "atom:\(name)")
        return nodes?.first?.stringValue
    }
}

// MARK: - PubMed

struct PubMedProvider: AcademicSearchProvider {
    let providerName = "PubMed"

    func search(query: String, limit: Int, year: String?) async -> [AcademicPaper] {
        // Step 1: esearch to get PMIDs
        guard let pmids = await esearch(query: query, limit: limit, year: year), !pmids.isEmpty
        else { return [] }

        // Step 2: efetch to get paper details
        return await efetch(pmids: pmids)
    }

    private func esearch(query: String, limit: Int, year: String?) async -> [String]? {
        var components = URLComponents(
            string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
        )!
        var items = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "retmax", value: String(limit)),
            URLQueryItem(name: "retmode", value: "json"),
            URLQueryItem(name: "sort", value: "relevance"),
        ]
        if let year, !year.isEmpty {
            if year.contains("-") {
                let parts = year.split(separator: "-")
                if parts.count == 2 {
                    items.append(URLQueryItem(name: "mindate", value: "\(parts[0])/01/01"))
                    items.append(URLQueryItem(name: "maxdate", value: "\(parts[1])/12/31"))
                    items.append(URLQueryItem(name: "datetype", value: "pdat"))
                }
            } else {
                items.append(URLQueryItem(name: "mindate", value: "\(year)/01/01"))
                items.append(URLQueryItem(name: "maxdate", value: "\(year)/12/31"))
                items.append(URLQueryItem(name: "datetype", value: "pdat"))
            }
        }
        components.queryItems = items

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let esearchResult = json["esearchresult"] as? [String: Any],
              let idList = esearchResult["idlist"] as? [String]
        else {
            Log.warning(Log.search, "PubMed esearch failed")
            return nil
        }

        return idList
    }

    private func efetch(pmids: [String]) async -> [AcademicPaper] {
        var components = URLComponents(
            string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"
        )!
        components.queryItems = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "id", value: pmids.joined(separator: ",")),
            URLQueryItem(name: "retmode", value: "xml"),
        ]

        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else {
            Log.warning(Log.search, "PubMed efetch failed")
            return []
        }

        return parsePubMedXML(data)
    }

    private func parsePubMedXML(_ data: Data) -> [AcademicPaper] {
        guard let doc = try? XMLDocument(data: data, options: []) else { return [] }

        guard let articles = try? doc.nodes(forXPath: "//PubmedArticle") else {
            return []
        }

        return articles.compactMap { node -> AcademicPaper? in
            guard let article = node as? XMLElement else { return nil }

            // Title
            let title = (try? article.nodes(forXPath: ".//ArticleTitle"))?
                .first?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let title, !title.isEmpty else { return nil }

            // Authors
            let authors: String
            if let authorNodes = try? article.nodes(forXPath: ".//Author") {
                authors = authorNodes.compactMap { authorNode -> String? in
                    guard let el = authorNode as? XMLElement else { return nil }
                    let lastName = (try? el.nodes(forXPath: "LastName"))?.first?.stringValue ?? ""
                    let foreName = (try? el.nodes(forXPath: "ForeName"))?.first?.stringValue ?? ""
                    let name = [foreName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
                    return name.isEmpty ? nil : name
                }.joined(separator: ", ")
            } else {
                authors = ""
            }

            // Year
            let year: Int?
            if let yearStr = (try? article.nodes(forXPath: ".//PubDate/Year"))?.first?.stringValue {
                year = Int(yearStr)
            } else {
                year = nil
            }

            // Abstract
            let abstract: String?
            if let abstractTexts = try? article.nodes(forXPath: ".//AbstractText") {
                let combined = abstractTexts.compactMap(\.stringValue).joined(separator: " ")
                abstract = combined.isEmpty ? nil : combined
            } else {
                abstract = nil
            }

            // DOI
            let doi: String?
            if let doiNodes = try? article.nodes(forXPath: ".//ArticleId[@IdType='doi']") {
                doi = doiNodes.first?.stringValue
            } else {
                doi = nil
            }

            // PMID for URL
            let pmid = (try? article.nodes(forXPath: ".//PMID"))?.first?.stringValue
            let url = pmid.map { "https://pubmed.ncbi.nlm.nih.gov/\($0)/" }

            // Venue
            let venue = (try? article.nodes(forXPath: ".//Journal/Title"))?.first?.stringValue

            return AcademicPaper(
                title: title,
                authors: authors,
                year: year,
                abstract: abstract,
                doi: doi,
                arxivId: nil,
                url: url,
                citationCount: nil,
                source: providerName,
                venue: venue
            )
        }
    }
}

// MARK: - Deduplication

enum AcademicPaperDeduplicator {

    /// Deduplicate papers across providers. Merges metadata from duplicates.
    static func deduplicate(_ groups: [(String, [AcademicPaper])]) -> [AcademicPaper] {
        // Track unique papers by DOI and normalized title
        var byDOI: [String: Int] = [:]           // lowercase DOI -> index in result
        var byTitle: [String: Int] = [:]          // normalized title -> index in result
        var result: [AcademicPaper] = []

        for (_, papers) in groups {
            for paper in papers {
                let normalizedDOI = paper.doi?.lowercased()
                let normalizedTitle = normalizeTitle(paper.title)

                // Check DOI match first (authoritative)
                if let doi = normalizedDOI, let existingIdx = byDOI[doi] {
                    result[existingIdx] = merge(existing: result[existingIdx], incoming: paper)
                    // Also register title for the merged entry
                    if !normalizedTitle.isEmpty {
                        byTitle[normalizedTitle] = existingIdx
                    }
                    continue
                }

                // Check title match (fallback)
                if !normalizedTitle.isEmpty, let existingIdx = byTitle[normalizedTitle] {
                    result[existingIdx] = merge(existing: result[existingIdx], incoming: paper)
                    // Also register DOI for the merged entry
                    if let doi = normalizedDOI {
                        byDOI[doi] = existingIdx
                    }
                    continue
                }

                // New unique paper
                let idx = result.count
                result.append(paper)
                if let doi = normalizedDOI {
                    byDOI[doi] = idx
                }
                if !normalizedTitle.isEmpty {
                    byTitle[normalizedTitle] = idx
                }
            }
        }

        return result
    }

    /// Strip non-alphanumeric, lowercase, for title-based dedup.
    private static func normalizeTitle(_ title: String) -> String {
        title.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map { String($0) }.joined()
    }

    /// Merge two duplicate papers: keep richest metadata, combine source names.
    private static func merge(existing: AcademicPaper, incoming: AcademicPaper) -> AcademicPaper {
        var merged = existing

        // Combine source names
        let existingSources = Set(existing.source.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        })
        let incomingSource = incoming.source.trimmingCharacters(in: .whitespaces)
        if !existingSources.contains(incomingSource) {
            merged.source = existing.source + ", " + incomingSource
        }

        // Fill gaps from incoming
        if merged.abstract == nil || (merged.abstract?.isEmpty ?? true) {
            merged.abstract = incoming.abstract
        }
        if merged.doi == nil { merged.doi = incoming.doi }
        if merged.arxivId == nil { merged.arxivId = incoming.arxivId }
        if merged.year == nil { merged.year = incoming.year }
        if merged.venue == nil { merged.venue = incoming.venue }
        if merged.url == nil { merged.url = incoming.url }
        if merged.authors.isEmpty { merged.authors = incoming.authors }

        // Prefer higher citation count
        if let ic = incoming.citationCount {
            if let ec = merged.citationCount {
                merged.citationCount = max(ec, ic)
            } else {
                merged.citationCount = ic
            }
        }

        return merged
    }
}

// MARK: - Ranking

enum AcademicPaperRanker {

    /// Score and sort papers. Returns top `limit` results.
    static func rank(_ papers: [AcademicPaper], limit: Int, currentYear: Int) -> [AcademicPaper] {
        let scored = papers.map { ($0, score($0, currentYear: currentYear)) }
        let sorted = scored.sorted { $0.1 > $1.1 }
        return Array(sorted.prefix(limit).map(\.0))
    }

    private static func score(_ paper: AcademicPaper, currentYear: Int) -> Double {
        var s = 0.0

        // Citation count: log-scaled, capped at 1.0
        if let c = paper.citationCount, c > 0 {
            s += min(log2(1.0 + Double(c)) / 10.0, 1.0)
        }

        // Multi-source corroboration: +0.3 per additional source
        let sourceCount = paper.source.split(separator: ",").count
        s += Double(sourceCount - 1) * 0.3

        // Metadata completeness: up to +0.5
        var completeness = 0.0
        if paper.abstract != nil { completeness += 0.15 }
        if paper.doi != nil { completeness += 0.15 }
        if paper.year != nil { completeness += 0.1 }
        if paper.venue != nil { completeness += 0.1 }
        s += completeness

        // Recency: +0.2 if within last 2 years
        if let y = paper.year, currentYear - y <= 2 {
            s += 0.2
        }

        return s
    }
}
