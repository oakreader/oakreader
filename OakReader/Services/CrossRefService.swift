import Foundation

/// Fetches bibliographic metadata from the CrossRef API and maps it to CSL JSON.
/// CrossRef API: https://api.crossref.org/works/{doi}
struct CrossRefService {

    /// Lookup metadata for a DOI via CrossRef.
    static func fetchMetadata(doi: String) async throws -> CSLItem {
        let encodedDOI = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        guard let url = URL(string: "https://api.crossref.org/works/\(encodedDOI)") else {
            throw CrossRefError.invalidDOI
        }

        var request = URLRequest(url: url)
        request.setValue("OakReader/1.0 (mailto:oakreader@example.com)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CrossRefError.networkError
        }
        guard httpResponse.statusCode == 200 else {
            throw CrossRefError.notFound
        }

        let wrapper = try JSONDecoder().decode(CrossRefResponse.self, from: data)
        return mapToCSLItem(wrapper.message)
    }

    // MARK: - Mapping

    private static func mapToCSLItem(_ msg: CrossRefMessage) -> CSLItem {
        var csl = CSLItem(type: mapType(msg.type ?? "other"))

        csl.title = msg.title?.first
        csl.containerTitle = msg.containerTitle?.first
        csl.publisher = msg.publisher
        csl.volume = msg.volume
        csl.issue = msg.issue
        csl.page = msg.page
        csl.DOI = msg.DOI
        csl.ISSN = msg.ISSN?.first
        csl.ISBN = msg.ISBN?.first
        csl.URL = msg.URL
        csl.language = msg.language
        csl.abstract = msg.abstract

        // Map authors
        csl.author = msg.author?.map { person in
            CSLName(family: person.family, given: person.given, literal: nil)
        }

        // Map editors
        csl.editor = msg.editor?.map { person in
            CSLName(family: person.family, given: person.given, literal: nil)
        }

        // Map date
        if let issued = msg.issued, let parts = issued.dateParts?.first {
            csl.issued = CSLDate(dateParts: [parts])
        }

        csl.shortTitle = msg.shortTitle?.first
        csl.journalAbbreviation = msg.shortContainerTitle?.first

        return csl
    }

    /// Map CrossRef type strings to CSL types.
    private static func mapType(_ crossRefType: String) -> String {
        switch crossRefType {
        case "journal-article": return "article-journal"
        case "book": return "book"
        case "book-chapter": return "chapter"
        case "proceedings-article": return "paper-conference"
        case "dissertation": return "thesis"
        case "report": return "report"
        case "posted-content": return "article"
        case "monograph": return "book"
        case "reference-entry": return "entry-encyclopedia"
        default: return "document"
        }
    }
}

// MARK: - CrossRef Response Types

enum CrossRefError: Error, LocalizedError {
    case invalidDOI
    case networkError
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidDOI: return "Invalid DOI format"
        case .networkError: return "Network error while contacting CrossRef"
        case .notFound: return "DOI not found in CrossRef"
        }
    }
}

private struct CrossRefResponse: Decodable {
    let status: String
    let message: CrossRefMessage
}

private struct CrossRefMessage: Decodable {
    let type: String?
    let title: [String]?
    let containerTitle: [String]?
    let publisher: String?
    let volume: String?
    let issue: String?
    let page: String?
    let DOI: String?
    let ISSN: [String]?
    let ISBN: [String]?
    let URL: String?
    let language: String?
    let abstract: String?
    let author: [CrossRefPerson]?
    let editor: [CrossRefPerson]?
    let issued: CrossRefDate?
    let shortTitle: [String]?
    let shortContainerTitle: [String]?

    enum CodingKeys: String, CodingKey {
        case type, title, publisher, volume, issue, page, DOI, ISSN, ISBN, URL
        case language, abstract, author, editor, issued
        case containerTitle = "container-title"
        case shortTitle = "short-title"
        case shortContainerTitle = "short-container-title"
    }
}

private struct CrossRefPerson: Decodable {
    let given: String?
    let family: String?
}

private struct CrossRefDate: Decodable {
    let dateParts: [[Int]]?

    enum CodingKeys: String, CodingKey {
        case dateParts = "date-parts"
    }
}
