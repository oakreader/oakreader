import Foundation

// MARK: - CSL JSON Data Types (Citation Style Language)

/// CSL JSON item representation.
/// See: https://citeproc-js.readthedocs.io/en/latest/csl-json/markup.html
struct CSLItem: Codable, Hashable {
    var type: String                    // "article-journal", "book", etc.
    var title: String?
    var containerTitle: String?         // journal, book title
    var publisher: String?
    var publisherPlace: String?
    var volume: String?
    var issue: String?
    var page: String?
    var edition: String?
    var abstract: String?
    var DOI: String?
    var ISBN: String?
    var ISSN: String?
    var URL: String?
    var language: String?
    var number: String?                 // report number, patent number
    var section: String?
    var genre: String?                  // thesis type, report type
    var shortTitle: String?
    var journalAbbreviation: String?
    var issued: CSLDate?
    var accessed: CSLDate?
    var author: [CSLName]?
    var editor: [CSLName]?
    var translator: [CSLName]?
    var collectionEditor: [CSLName]?
    var note: String?

    enum CodingKeys: String, CodingKey {
        case type, title, publisher, volume, issue, page, edition
        case abstract, DOI, ISBN, ISSN, URL, language, number, section, genre, note
        case containerTitle = "container-title"
        case publisherPlace = "publisher-place"
        case shortTitle = "short-title"
        case journalAbbreviation = "journal-abbreviation"
        case issued, accessed, author, editor, translator
        case collectionEditor = "collection-editor"
    }
}

struct CSLDate: Codable, Hashable {
    var dateParts: [[Int]]?             // [[2024, 3, 15]] or [[2024]]
    var raw: String?                    // Fallback raw date string

    enum CodingKeys: String, CodingKey {
        case dateParts = "date-parts"
        case raw
    }

    var year: Int? { dateParts?.first?.first }
    var month: Int? {
        guard let parts = dateParts?.first, parts.count > 1 else { return nil }
        return parts[1]
    }
    var day: Int? {
        guard let parts = dateParts?.first, parts.count > 2 else { return nil }
        return parts[2]
    }

    init(year: Int, month: Int? = nil, day: Int? = nil) {
        var parts = [year]
        if let month { parts.append(month) }
        if let day { parts.append(day) }
        self.dateParts = [parts]
        self.raw = nil
    }

    init(dateParts: [[Int]]? = nil, raw: String? = nil) {
        self.dateParts = dateParts
        self.raw = raw
    }
}

struct CSLName: Codable, Hashable {
    var family: String?
    var given: String?
    var literal: String?                // For institutional names

    var displayString: String {
        if let lit = literal, !lit.isEmpty { return lit }
        let initial = (given ?? "").isEmpty ? "" : "\(given!.prefix(1))."
        return [(family ?? ""), initial].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    var fullDisplayString: String {
        if let lit = literal, !lit.isEmpty { return lit }
        return [(given ?? ""), (family ?? "")].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - CSL Item Type Enum (UI display)

enum CSLItemType: String, CaseIterable, Identifiable {
    case articleJournal = "article-journal"
    case book = "book"
    case chapter = "chapter"
    case paperConference = "paper-conference"
    case thesis = "thesis"
    case report = "report"
    case webpage = "webpage"
    case articleNewspaper = "article-newspaper"
    case articleMagazine = "article-magazine"
    case patent = "patent"
    case document = "document"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .articleJournal: return "Journal Article"
        case .book: return "Book"
        case .chapter: return "Book Chapter"
        case .paperConference: return "Conference Paper"
        case .thesis: return "Thesis"
        case .report: return "Report"
        case .webpage: return "Webpage"
        case .articleNewspaper: return "Newspaper Article"
        case .articleMagazine: return "Magazine Article"
        case .patent: return "Patent"
        case .document: return "Document"
        }
    }

    var icon: String {
        switch self {
        case .articleJournal: return "doc.text"
        case .book: return "book.closed"
        case .chapter: return "book.pages"
        case .paperConference: return "person.3"
        case .thesis: return "graduationcap"
        case .report: return "doc.badge.gearshape"
        case .webpage: return "globe"
        case .articleNewspaper: return "newspaper"
        case .articleMagazine: return "magazine"
        case .patent: return "lightbulb"
        case .document: return "doc"
        }
    }
}

// MARK: - Citation Style Enum

enum CitationStyle: String, CaseIterable, Identifiable {
    case apa
    case mla
    case chicago
    case bibtex
    case ris
    case cslJson

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apa: return "APA"
        case .mla: return "MLA"
        case .chicago: return "Chicago"
        case .bibtex: return "BibTeX"
        case .ris: return "RIS"
        case .cslJson: return "CSL JSON"
        }
    }

    var isHumanReadable: Bool {
        switch self {
        case .apa, .mla, .chicago: return true
        case .bibtex, .ris, .cslJson: return false
        }
    }
}
