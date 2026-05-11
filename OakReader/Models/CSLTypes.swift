import Foundation

// MARK: - CSL JSON Data Types (Citation Style Language)

/// Maps Swift property names ↔ CSL JSON hyphenated keys.
/// Single source of truth: add a field = add ONE case.
enum CSLFieldKey: String, CaseIterable, Hashable {
    case title, publisher, volume, issue, page, edition
    case abstract, DOI, ISBN, ISSN, URL, language, number, section, genre, note
    case medium, source, dimensions, scale, annote, status, archive, version, authority
    case containerTitle, publisherPlace, shortTitle, journalAbbreviation
    case collectionTitle, numberOfPages, numberOfVolumes
    case eventTitle, eventPlace, originalTitle, reviewedTitle, chapterNumber
    case archiveLocation, callNumber, collectionNumber

    /// CSL JSON wire key (hyphenated).
    var jsonKey: String {
        switch self {
        case .containerTitle:       return "container-title"
        case .publisherPlace:       return "publisher-place"
        case .shortTitle:           return "short-title"
        case .journalAbbreviation:  return "journal-abbreviation"
        case .collectionTitle:      return "collection-title"
        case .numberOfPages:        return "number-of-pages"
        case .numberOfVolumes:      return "number-of-volumes"
        case .eventTitle:           return "event-title"
        case .eventPlace:           return "event-place"
        case .originalTitle:        return "original-title"
        case .reviewedTitle:        return "reviewed-title"
        case .chapterNumber:        return "chapter-number"
        case .archiveLocation:      return "archive-location"
        case .callNumber:           return "call-number"
        case .collectionNumber:     return "collection-number"
        default:                    return rawValue
        }
    }

    /// Reverse lookup: CSL JSON key → enum case.
    static let byJSONKey: [String: CSLFieldKey] = {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.jsonKey, $0) })
    }()
}

/// Maps Swift property names ↔ CSL JSON creator role keys.
/// Single source of truth: add a role = add ONE case.
enum CSLCreatorRole: String, CaseIterable, Hashable {
    case author, editor, translator, director, illustrator, composer
    case recipient, interviewer, compiler, curator, guest, host
    case narrator, organizer, performer, producer
    case collectionEditor, reviewedAuthor, containerAuthor
    case editorialDirector, executiveProducer, scriptWriter

    var jsonKey: String {
        switch self {
        case .collectionEditor:     return "collection-editor"
        case .reviewedAuthor:       return "reviewed-author"
        case .containerAuthor:      return "container-author"
        case .editorialDirector:    return "editorial-director"
        case .executiveProducer:    return "executive-producer"
        case .scriptWriter:         return "script-writer"
        default:                    return rawValue
        }
    }

    var displayName: String {
        switch self {
        case .author:               return "Author"
        case .editor:               return "Editor"
        case .translator:           return "Translator"
        case .collectionEditor:     return "Series Editor"
        case .director:             return "Director"
        case .illustrator:          return "Illustrator"
        case .composer:             return "Composer"
        case .recipient:            return "Recipient"
        case .interviewer:          return "Interviewer"
        case .reviewedAuthor:       return "Reviewed Author"
        case .containerAuthor:      return "Book Author"
        case .editorialDirector:    return "Editorial Director"
        case .compiler:             return "Compiler"
        case .curator:              return "Curator"
        case .executiveProducer:    return "Executive Producer"
        case .guest:                return "Guest"
        case .host:                 return "Host"
        case .narrator:             return "Narrator"
        case .organizer:            return "Organizer"
        case .performer:            return "Performer"
        case .producer:             return "Producer"
        case .scriptWriter:         return "Scriptwriter"
        }
    }

    static let byJSONKey: [String: CSLCreatorRole] = {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.jsonKey, $0) })
    }()
}

// MARK: - CSLItem

/// CSL JSON item. Dictionary-backed with subscript access.
///
///     csl[.title] = "My Paper"          // by enum key
///     csl[jsonKey: "container-title"]    // by wire key (for import code)
///     csl[.author]                      // creator subscript
///     csl.title                         // dot access for common fields
///
struct CSLItem: Hashable {
    var type: String = "document"
    var fields: [CSLFieldKey: String] = [:]
    var creators: [CSLCreatorRole: [CSLName]] = [:]
    var issued: CSLDate?
    var accessed: CSLDate?

    init(type: String) { self.type = type }

    // MARK: - Subscripts

    /// Access a string field by enum key.
    subscript(field: CSLFieldKey) -> String? {
        get { fields[field] }
        set {
            if let newValue, !newValue.isEmpty { fields[field] = newValue }
            else { fields.removeValue(forKey: field) }
        }
    }

    /// Access a string field by CSL JSON key (for import/migration code).
    subscript(jsonKey key: String) -> String? {
        get { CSLFieldKey.byJSONKey[key].flatMap { fields[$0] } }
        set {
            guard let fk = CSLFieldKey.byJSONKey[key] else { return }
            self[fk] = newValue
        }
    }

    /// Access a creator array by enum role.
    subscript(role: CSLCreatorRole) -> [CSLName]? {
        get { creators[role] }
        set {
            if let newValue, !newValue.isEmpty { creators[role] = newValue }
            else { creators.removeValue(forKey: role) }
        }
    }

    // MARK: - Creator Helpers

    /// Access creators by CSL JSON role key string.
    func getCreators(role: String) -> [CSLName]? {
        CSLCreatorRole.byJSONKey[role].flatMap { creators[$0] }
    }

    mutating func setCreators(role: String, names: [CSLName]?) {
        guard let r = CSLCreatorRole.byJSONKey[role] else { return }
        self[r] = names
    }

    /// All non-empty creator groups.
    func allCreators() -> [(role: String, names: [CSLName])] {
        creators.compactMap { (role, names) in
            names.isEmpty ? nil : (role: role.jsonKey, names: names)
        }
    }

    static let allCreatorRoles: [String] = CSLCreatorRole.allCases.map(\.jsonKey)

    static func creatorRoleDisplayName(_ role: String) -> String {
        CSLCreatorRole.byJSONKey[role]?.displayName ?? role.capitalized
    }

    // MARK: - Field access by Swift property name (for CSLTypeFieldSpec keys)

    func getField(_ key: String) -> String? {
        CSLFieldKey(rawValue: key).flatMap { fields[$0] }
    }

    mutating func setField(_ key: String, value: String?) {
        guard let fk = CSLFieldKey(rawValue: key) else { return }
        self[fk] = value
    }

    // MARK: - Dot-access (frequently used fields only)

    var title: String? {
        get { self[.title] }
        set { self[.title] = newValue }
    }
    var containerTitle: String? {
        get { self[.containerTitle] }
        set { self[.containerTitle] = newValue }
    }
    var publisher: String? {
        get { self[.publisher] }
        set { self[.publisher] = newValue }
    }
    var publisherPlace: String? {
        get { self[.publisherPlace] }
        set { self[.publisherPlace] = newValue }
    }
    var volume: String? {
        get { self[.volume] }
        set { self[.volume] = newValue }
    }
    var issue: String? {
        get { self[.issue] }
        set { self[.issue] = newValue }
    }
    var page: String? {
        get { self[.page] }
        set { self[.page] = newValue }
    }
    var edition: String? {
        get { self[.edition] }
        set { self[.edition] = newValue }
    }
    var abstract: String? {
        get { self[.abstract] }
        set { self[.abstract] = newValue }
    }
    var DOI: String? {
        get { self[.DOI] }
        set { self[.DOI] = newValue }
    }
    var ISBN: String? {
        get { self[.ISBN] }
        set { self[.ISBN] = newValue }
    }
    var ISSN: String? {
        get { self[.ISSN] }
        set { self[.ISSN] = newValue }
    }
    var URL: String? {
        get { self[.URL] }
        set { self[.URL] = newValue }
    }
    var language: String? {
        get { self[.language] }
        set { self[.language] = newValue }
    }
    var number: String? {
        get { self[.number] }
        set { self[.number] = newValue }
    }
    var section: String? {
        get { self[.section] }
        set { self[.section] = newValue }
    }
    var genre: String? {
        get { self[.genre] }
        set { self[.genre] = newValue }
    }
    var shortTitle: String? {
        get { self[.shortTitle] }
        set { self[.shortTitle] = newValue }
    }
    var journalAbbreviation: String? {
        get { self[.journalAbbreviation] }
        set { self[.journalAbbreviation] = newValue }
    }
    var note: String? {
        get { self[.note] }
        set { self[.note] = newValue }
    }
    var collectionTitle: String? {
        get { self[.collectionTitle] }
        set { self[.collectionTitle] = newValue }
    }
    var numberOfPages: String? {
        get { self[.numberOfPages] }
        set { self[.numberOfPages] = newValue }
    }
    var medium: String? {
        get { self[.medium] }
        set { self[.medium] = newValue }
    }
    var source: String? {
        get { self[.source] }
        set { self[.source] = newValue }
    }
    var eventTitle: String? {
        get { self[.eventTitle] }
        set { self[.eventTitle] = newValue }
    }
    var archive: String? {
        get { self[.archive] }
        set { self[.archive] = newValue }
    }
    var archiveLocation: String? {
        get { self[.archiveLocation] }
        set { self[.archiveLocation] = newValue }
    }
    var version: String? {
        get { self[.version] }
        set { self[.version] = newValue }
    }
    var authority: String? {
        get { self[.authority] }
        set { self[.authority] = newValue }
    }
    var dimensions: String? {
        get { self[.dimensions] }
        set { self[.dimensions] = newValue }
    }
    var scale: String? {
        get { self[.scale] }
        set { self[.scale] = newValue }
    }
    var reviewedTitle: String? {
        get { self[.reviewedTitle] }
        set { self[.reviewedTitle] = newValue }
    }
    var numberOfVolumes: String? {
        get { self[.numberOfVolumes] }
        set { self[.numberOfVolumes] = newValue }
    }
    var collectionNumber: String? {
        get { self[.collectionNumber] }
        set { self[.collectionNumber] = newValue }
    }
    var chapterNumber: String? {
        get { self[.chapterNumber] }
        set { self[.chapterNumber] = newValue }
    }
    var eventPlace: String? {
        get { self[.eventPlace] }
        set { self[.eventPlace] = newValue }
    }
    var callNumber: String? {
        get { self[.callNumber] }
        set { self[.callNumber] = newValue }
    }
    var annote: String? {
        get { self[.annote] }
        set { self[.annote] = newValue }
    }
    var status: String? {
        get { self[.status] }
        set { self[.status] = newValue }
    }
    var originalTitle: String? {
        get { self[.originalTitle] }
        set { self[.originalTitle] = newValue }
    }

    // Creator dot-access
    var author: [CSLName]? {
        get { self[.author] }
        set { self[.author] = newValue }
    }
    var editor: [CSLName]? {
        get { self[.editor] }
        set { self[.editor] = newValue }
    }
    var translator: [CSLName]? {
        get { self[.translator] }
        set { self[.translator] = newValue }
    }
    var collectionEditor: [CSLName]? {
        get { self[.collectionEditor] }
        set { self[.collectionEditor] = newValue }
    }
    var director: [CSLName]? {
        get { self[.director] }
        set { self[.director] = newValue }
    }
    var performer: [CSLName]? {
        get { self[.performer] }
        set { self[.performer] = newValue }
    }
    var composer: [CSLName]? {
        get { self[.composer] }
        set { self[.composer] = newValue }
    }
    var producer: [CSLName]? {
        get { self[.producer] }
        set { self[.producer] = newValue }
    }
}

// MARK: - Codable

extension CSLItem: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        type = (try? container.decode(String.self, forKey: DynamicCodingKey("type"))) ?? "document"
        for fk in CSLFieldKey.allCases {
            if let val = try? container.decode(String.self, forKey: DynamicCodingKey(fk.jsonKey)) {
                fields[fk] = val
            }
        }
        for role in CSLCreatorRole.allCases {
            if let names = try? container.decode([CSLName].self, forKey: DynamicCodingKey(role.jsonKey)) {
                creators[role] = names
            }
        }
        issued = try? container.decode(CSLDate.self, forKey: DynamicCodingKey("issued"))
        accessed = try? container.decode(CSLDate.self, forKey: DynamicCodingKey("accessed"))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        try container.encode(type, forKey: DynamicCodingKey("type"))
        for (fk, val) in fields {
            try container.encode(val, forKey: DynamicCodingKey(fk.jsonKey))
        }
        for (role, names) in creators where !names.isEmpty {
            try container.encode(names, forKey: DynamicCodingKey(role.jsonKey))
        }
        if let issued { try container.encode(issued, forKey: DynamicCodingKey("issued")) }
        if let accessed { try container.encode(accessed, forKey: DynamicCodingKey("accessed")) }
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// MARK: - CSLDate

struct CSLDate: Codable, Hashable {
    var dateParts: [[Int]]?
    var raw: String?

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

// MARK: - CSLName

struct CSLName: Codable, Hashable {
    var family: String?
    var given: String?
    var literal: String?

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

// MARK: - CSL Item Type Enum

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
    case motionPicture = "motion_picture"
    case document = "document"
    case article = "article"
    case software = "software"
    case graphic = "graphic"
    case speech = "speech"
    case interview = "interview"
    case personalCommunication = "personal_communication"
    case manuscript = "manuscript"
    case map = "map"
    case legislation = "legislation"
    case bill = "bill"
    case legalCase = "legal_case"
    case hearing = "hearing"
    case entryEncyclopedia = "entry-encyclopedia"
    case entryDictionary = "entry-dictionary"
    case postWeblog = "post-weblog"
    case post = "post"
    case broadcast = "broadcast"
    case song = "song"
    case dataset = "dataset"
    case standard = "standard"
    case review = "review"
    case regulation = "regulation"
    case treaty = "treaty"

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
        case .motionPicture: return "Video"
        case .document: return "Document"
        case .article: return "Preprint"
        case .software: return "Software"
        case .graphic: return "Artwork"
        case .speech: return "Presentation"
        case .interview: return "Interview"
        case .personalCommunication: return "Letter / Email"
        case .manuscript: return "Manuscript"
        case .map: return "Map"
        case .legislation: return "Statute"
        case .bill: return "Bill"
        case .legalCase: return "Legal Case"
        case .hearing: return "Hearing"
        case .entryEncyclopedia: return "Encyclopedia Entry"
        case .entryDictionary: return "Dictionary Entry"
        case .postWeblog: return "Blog Post"
        case .post: return "Forum Post"
        case .broadcast: return "Broadcast"
        case .song: return "Audio Recording"
        case .dataset: return "Dataset"
        case .standard: return "Standard"
        case .review: return "Review"
        case .regulation: return "Regulation"
        case .treaty: return "Treaty"
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
        case .motionPicture: return "film"
        case .document: return "doc"
        case .article: return "doc.text.below.ecg"
        case .software: return "desktopcomputer"
        case .graphic: return "paintbrush"
        case .speech: return "person.wave.2"
        case .interview: return "mic"
        case .personalCommunication: return "envelope"
        case .manuscript: return "scroll"
        case .map: return "map"
        case .legislation: return "building.columns"
        case .bill: return "doc.text.magnifyingglass"
        case .legalCase: return "briefcase"
        case .hearing: return "person.3.sequence"
        case .entryEncyclopedia: return "books.vertical"
        case .entryDictionary: return "character.book.closed"
        case .postWeblog: return "text.bubble"
        case .post: return "bubble.left.and.bubble.right"
        case .broadcast: return "antenna.radiowaves.left.and.right"
        case .song: return "music.note"
        case .dataset: return "tablecells"
        case .standard: return "checkmark.seal"
        case .review: return "star.bubble"
        case .regulation: return "building.columns.fill"
        case .treaty: return "signature"
        }
    }
}

// MARK: - Citation Style Enum

enum CitationStyle: String, CaseIterable, Identifiable {
    case apa, mla, chicago, bibtex, ris, cslJson

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
