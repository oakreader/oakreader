import Foundation

/// Formats CSLItem data into various citation styles and machine-readable formats.
enum CitationFormatter {

    // MARK: - Human-Readable Styles

    /// APA 7th edition format.
    /// Example: Smith, J., & Doe, A. (2024). Title. *Journal*, 1(2), 1-10. https://doi.org/...
    static func toAPA(csl: CSLItem) -> String {
        var parts: [String] = []

        // Authors
        let authors = csl.author ?? []
        if !authors.isEmpty {
            parts.append(formatAPAAuthors(authors))
        }

        // Year
        if let year = csl.issued?.year {
            parts.append("(\(year)).")
        }

        // Title
        if let title = csl.title {
            parts.append("\(title).")
        }

        // Container (journal, book title)
        if let container = csl.containerTitle {
            var journalPart = "*\(container)*"
            if let vol = csl.volume {
                journalPart += ", *\(vol)*"
                if let issue = csl.issue {
                    journalPart += "(\(issue))"
                }
            }
            if let page = csl.page {
                journalPart += ", \(page)"
            }
            journalPart += "."
            parts.append(journalPart)
        } else {
            // Publisher for books
            if let publisher = csl.publisher {
                parts.append("\(publisher).")
            }
        }

        // DOI
        if let doi = csl.DOI {
            parts.append("https://doi.org/\(doi)")
        }

        return parts.joined(separator: " ")
    }

    /// MLA 9th edition format.
    /// Example: Smith, John, and Alice Doe. "Title." *Journal*, vol. 1, no. 2, 2024, pp. 1-10.
    static func toMLA(csl: CSLItem) -> String {
        var parts: [String] = []

        // Authors
        let authors = csl.author ?? []
        if !authors.isEmpty {
            parts.append(formatMLAAuthors(authors) + ".")
        }

        // Title in quotes (for articles) or italics (for books)
        if let title = csl.title {
            if csl.containerTitle != nil {
                parts.append("\"\(title).\"")
            } else {
                parts.append("*\(title)*.")
            }
        }

        // Container
        if let container = csl.containerTitle {
            var containerPart = "*\(container)*"
            var details: [String] = []
            if let vol = csl.volume { details.append("vol. \(vol)") }
            if let issue = csl.issue { details.append("no. \(issue)") }
            if let year = csl.issued?.year { details.append("\(year)") }
            if let page = csl.page { details.append("pp. \(page)") }
            if !details.isEmpty {
                containerPart += ", " + details.joined(separator: ", ")
            }
            containerPart += "."
            parts.append(containerPart)
        } else if let publisher = csl.publisher {
            var pubPart = publisher
            if let year = csl.issued?.year { pubPart += ", \(year)" }
            pubPart += "."
            parts.append(pubPart)
        }

        return parts.joined(separator: " ")
    }

    /// Chicago (Notes-Bibliography) format.
    /// Example: Smith, John, and Alice Doe. "Title." *Journal* 1, no. 2 (2024): 1-10.
    static func toChicago(csl: CSLItem) -> String {
        var parts: [String] = []

        // Authors
        let authors = csl.author ?? []
        if !authors.isEmpty {
            parts.append(formatChicagoAuthors(authors) + ".")
        }

        // Title
        if let title = csl.title {
            if csl.containerTitle != nil {
                parts.append("\"\(title).\"")
            } else {
                parts.append("*\(title)*.")
            }
        }

        // Container
        if let container = csl.containerTitle {
            var containerPart = "*\(container)*"
            if let vol = csl.volume {
                containerPart += " \(vol)"
            }
            if let issue = csl.issue {
                containerPart += ", no. \(issue)"
            }
            if let year = csl.issued?.year {
                containerPart += " (\(year))"
            }
            if let page = csl.page {
                containerPart += ": \(page)"
            }
            containerPart += "."
            parts.append(containerPart)
        } else if let publisher = csl.publisher {
            var pubPart = ""
            if let place = csl.publisherPlace { pubPart += "\(place): " }
            pubPart += publisher
            if let year = csl.issued?.year { pubPart += ", \(year)" }
            pubPart += "."
            parts.append(pubPart)
        }

        return parts.joined(separator: " ")
    }

    // MARK: - Machine Formats

    /// BibTeX format.
    static func toBibTeX(csl: CSLItem, citeKey: String? = nil) -> String {
        let entryType = bibTeXType(csl.type)
        let key = citeKey ?? generateCiteKey(csl)

        var fields: [(String, String)] = []

        if let authors = csl.author, !authors.isEmpty {
            fields.append(("author", authors.map { bibTeXName($0) }.joined(separator: " and ")))
        }
        if let title = csl.title { fields.append(("title", "{\(title)}")) }
        if let container = csl.containerTitle { fields.append(("journal", container)) }
        if let year = csl.issued?.year { fields.append(("year", "\(year)")) }
        if let vol = csl.volume { fields.append(("volume", vol)) }
        if let issue = csl.issue { fields.append(("number", issue)) }
        if let page = csl.page { fields.append(("pages", page.replacingOccurrences(of: "-", with: "--"))) }
        if let publisher = csl.publisher { fields.append(("publisher", publisher)) }
        if let doi = csl.DOI { fields.append(("doi", doi)) }
        if let isbn = csl.ISBN { fields.append(("isbn", isbn)) }
        if let issn = csl.ISSN { fields.append(("issn", issn)) }
        if let url = csl.URL { fields.append(("url", url)) }
        if let abstract = csl.abstract { fields.append(("abstract", "{\(abstract)}")) }

        let fieldLines = fields.map { "  \($0.0) = {\($0.1)}" }.joined(separator: ",\n")
        return "@\(entryType){\(key),\n\(fieldLines)\n}"
    }

    /// RIS format.
    static func toRIS(csl: CSLItem) -> String {
        var lines: [String] = []

        lines.append("TY  - \(risType(csl.type))")

        if let title = csl.title { lines.append("TI  - \(title)") }
        for author in csl.author ?? [] {
            lines.append("AU  - \(risName(author))")
        }
        for editor in csl.editor ?? [] {
            lines.append("ED  - \(risName(editor))")
        }
        if let container = csl.containerTitle { lines.append("JO  - \(container)") }
        if let year = csl.issued?.year { lines.append("PY  - \(year)") }
        if let vol = csl.volume { lines.append("VL  - \(vol)") }
        if let issue = csl.issue { lines.append("IS  - \(issue)") }
        if let page = csl.page {
            let parts = page.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count >= 2 {
                lines.append("SP  - \(parts[0])")
                lines.append("EP  - \(parts[1])")
            } else {
                lines.append("SP  - \(page)")
            }
        }
        if let publisher = csl.publisher { lines.append("PB  - \(publisher)") }
        if let doi = csl.DOI { lines.append("DO  - \(doi)") }
        if let url = csl.URL { lines.append("UR  - \(url)") }
        if let isbn = csl.ISBN { lines.append("SN  - \(isbn)") }
        if let issn = csl.ISSN { lines.append("SN  - \(issn)") }
        if let abstract = csl.abstract { lines.append("AB  - \(abstract)") }
        if let language = csl.language { lines.append("LA  - \(language)") }

        lines.append("ER  -")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    /// Pretty-printed CSL JSON.
    static func toCSLJSON(csl: CSLItem) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(csl),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    // MARK: - Import

    /// Parse a BibTeX string into CSLItems.
    static func parseBibTeX(_ bibtex: String) -> [CSLItem] {
        var items: [CSLItem] = []
        // Simple BibTeX parser: find entries
        // swiftlint:disable:next force_try
        let entryPattern = try! NSRegularExpression(
            pattern: #"@(\w+)\{([^,]+),\s*([\s\S]*?)\n\}"#
        )
        let range = NSRange(bibtex.startIndex..., in: bibtex)
        let matches = entryPattern.matches(in: bibtex, range: range)

        for match in matches {
            guard let typeRange = Range(match.range(at: 1), in: bibtex),
                  let fieldsRange = Range(match.range(at: 3), in: bibtex) else { continue }

            let entryType = String(bibtex[typeRange]).lowercased()
            let fieldsStr = String(bibtex[fieldsRange])

            var csl = CSLItem(type: cslTypeFromBibTeX(entryType))
            let fields = parseBibTeXFields(fieldsStr)

            csl.title = fields["title"]
            csl.containerTitle = fields["journal"] ?? fields["booktitle"]
            csl.publisher = fields["publisher"]
            csl.volume = fields["volume"]
            csl.issue = fields["number"]
            csl.page = fields["pages"]?.replacingOccurrences(of: "--", with: "-")
            csl.DOI = fields["doi"]
            csl.ISBN = fields["isbn"]
            csl.ISSN = fields["issn"]
            csl.URL = fields["url"]
            csl.abstract = fields["abstract"]

            if let yearStr = fields["year"], let year = Int(yearStr) {
                csl.issued = CSLDate(year: year)
            }

            if let authorStr = fields["author"] {
                csl.author = parseBibTeXNames(authorStr)
            }
            if let editorStr = fields["editor"] {
                csl.editor = parseBibTeXNames(editorStr)
            }

            items.append(csl)
        }
        return items
    }

    /// Parse an RIS string into CSLItems.
    static func parseRIS(_ ris: String) -> [CSLItem] {
        var items: [CSLItem] = []
        var current: CSLItem?
        var currentAuthors: [CSLName] = []
        var currentEditors: [CSLName] = []
        var startPage: String?
        var endPage: String?

        for line in ris.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 6 else { continue }

            let tag = String(trimmed.prefix(2))
            let valueStart = trimmed.index(trimmed.startIndex, offsetBy: 6, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)

            switch tag {
            case "TY":
                current = CSLItem(type: cslTypeFromRIS(value))
                currentAuthors = []
                currentEditors = []
                startPage = nil
                endPage = nil
            case "TI", "T1":
                current?.title = value
            case "AU", "A1":
                currentAuthors.append(parseRISName(value))
            case "ED", "A2":
                currentEditors.append(parseRISName(value))
            case "JO", "JF", "T2":
                current?.containerTitle = value
            case "PY", "Y1":
                if let year = Int(value.prefix(4)) {
                    current?.issued = CSLDate(year: year)
                }
            case "VL":
                current?.volume = value
            case "IS":
                current?.issue = value
            case "SP":
                startPage = value
            case "EP":
                endPage = value
            case "PB":
                current?.publisher = value
            case "DO":
                current?.DOI = value
            case "UR":
                current?.URL = value
            case "SN":
                // Could be ISBN or ISSN
                if value.contains("-") && value.count <= 10 {
                    current?.ISSN = value
                } else {
                    current?.ISBN = value
                }
            case "AB", "N2":
                current?.abstract = value
            case "LA":
                current?.language = value
            case "ER":
                if var item = current {
                    if !currentAuthors.isEmpty { item.author = currentAuthors }
                    if !currentEditors.isEmpty { item.editor = currentEditors }
                    if let sp = startPage {
                        item.page = endPage != nil ? "\(sp)-\(endPage!)" : sp
                    }
                    items.append(item)
                }
                current = nil
            default:
                break
            }
        }
        return items
    }

    // MARK: - Private Helpers

    private static func formatAPAAuthors(_ authors: [CSLName]) -> String {
        let formatted = authors.map { name -> String in
            if let lit = name.literal, !lit.isEmpty { return lit }
            let initial = (name.given ?? "").isEmpty ? "" : " \(name.given!.prefix(1))."
            return (name.family ?? "") + initial
        }

        switch formatted.count {
        case 0: return ""
        case 1: return formatted[0] + "."
        case 2: return "\(formatted[0]) & \(formatted[1])."
        default:
            let allButLast = formatted.dropLast().joined(separator: ", ")
            return "\(allButLast), & \(formatted.last!)."
        }
    }

    private static func formatMLAAuthors(_ authors: [CSLName]) -> String {
        let formatted = authors.enumerated().map { (i, name) -> String in
            if let lit = name.literal, !lit.isEmpty { return lit }
            if i == 0 {
                // First author: Last, First
                return [(name.family ?? ""), (name.given ?? "")].filter { !$0.isEmpty }.joined(separator: ", ")
            } else {
                // Subsequent: First Last
                return name.fullDisplayString
            }
        }

        switch formatted.count {
        case 0: return ""
        case 1: return formatted[0]
        case 2: return "\(formatted[0]), and \(formatted[1])"
        default:
            if formatted.count > 3 {
                return "\(formatted[0]), et al"
            }
            let allButLast = formatted.dropLast().joined(separator: ", ")
            return "\(allButLast), and \(formatted.last!)"
        }
    }

    private static func formatChicagoAuthors(_ authors: [CSLName]) -> String {
        let formatted = authors.enumerated().map { (i, name) -> String in
            if let lit = name.literal, !lit.isEmpty { return lit }
            if i == 0 {
                return [(name.family ?? ""), (name.given ?? "")].filter { !$0.isEmpty }.joined(separator: ", ")
            } else {
                return name.fullDisplayString
            }
        }

        switch formatted.count {
        case 0: return ""
        case 1: return formatted[0]
        case 2: return "\(formatted[0]), and \(formatted[1])"
        default:
            if formatted.count > 10 {
                let first7 = formatted.prefix(7).joined(separator: ", ")
                return "\(first7), et al"
            }
            let allButLast = formatted.dropLast().joined(separator: ", ")
            return "\(allButLast), and \(formatted.last!)"
        }
    }

    private static func bibTeXType(_ cslType: String) -> String {
        switch cslType {
        case "article-journal": return "article"
        case "book": return "book"
        case "chapter": return "incollection"
        case "paper-conference": return "inproceedings"
        case "thesis": return "phdthesis"
        case "report": return "techreport"
        default: return "misc"
        }
    }

    private static func risType(_ cslType: String) -> String {
        switch cslType {
        case "article-journal": return "JOUR"
        case "book": return "BOOK"
        case "chapter": return "CHAP"
        case "paper-conference": return "CONF"
        case "thesis": return "THES"
        case "report": return "RPRT"
        case "webpage": return "ELEC"
        default: return "GEN"
        }
    }

    private static func generateCiteKey(_ csl: CSLItem) -> String {
        let author = csl.author?.first?.family?.lowercased()
            .replacingOccurrences(of: " ", with: "") ?? "unknown"
        let year = csl.issued?.year.map { "\($0)" } ?? "nd"
        let titleWord = csl.title?.split(separator: " ").first.map { String($0).lowercased() } ?? "untitled"
        return "\(author)\(year)\(titleWord)"
    }

    private static func bibTeXName(_ name: CSLName) -> String {
        if let lit = name.literal, !lit.isEmpty { return "{\(lit)}" }
        return [(name.family ?? ""), (name.given ?? "")].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func risName(_ name: CSLName) -> String {
        if let lit = name.literal, !lit.isEmpty { return lit }
        return [(name.family ?? ""), (name.given ?? "")].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private static func cslTypeFromBibTeX(_ bibtex: String) -> String {
        switch bibtex {
        case "article": return "article-journal"
        case "book": return "book"
        case "incollection", "inbook": return "chapter"
        case "inproceedings", "conference": return "paper-conference"
        case "phdthesis", "mastersthesis": return "thesis"
        case "techreport": return "report"
        default: return "document"
        }
    }

    private static func cslTypeFromRIS(_ ris: String) -> String {
        switch ris {
        case "JOUR", "JFULL": return "article-journal"
        case "BOOK": return "book"
        case "CHAP": return "chapter"
        case "CONF", "CPAPER": return "paper-conference"
        case "THES": return "thesis"
        case "RPRT": return "report"
        case "ELEC": return "webpage"
        default: return "document"
        }
    }

    private static func parseBibTeXFields(_ fieldsStr: String) -> [String: String] {
        var fields: [String: String] = [:]
        // swiftlint:disable:next force_try
        let fieldPattern = try! NSRegularExpression(
            pattern: #"(\w+)\s*=\s*\{([^}]*)\}"#
        )
        let range = NSRange(fieldsStr.startIndex..., in: fieldsStr)
        let matches = fieldPattern.matches(in: fieldsStr, range: range)

        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: fieldsStr),
                  let valueRange = Range(match.range(at: 2), in: fieldsStr) else { continue }
            let key = String(fieldsStr[keyRange]).lowercased()
            let value = String(fieldsStr[valueRange])
            fields[key] = value
        }
        return fields
    }

    private static func parseBibTeXNames(_ nameStr: String) -> [CSLName] {
        nameStr.components(separatedBy: " and ").map { part in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "{", with: "")
                .replacingOccurrences(of: "}", with: "")
            let parts = trimmed.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                return CSLName(family: parts[0], given: parts[1])
            } else {
                // "First Last" format
                let words = trimmed.split(separator: " ")
                if words.count >= 2 {
                    let family = String(words.last!)
                    let given = words.dropLast().joined(separator: " ")
                    return CSLName(family: family, given: given)
                }
                return CSLName(family: trimmed, given: nil)
            }
        }
    }

    private static func parseRISName(_ value: String) -> CSLName {
        let parts = value.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2 {
            return CSLName(family: parts[0], given: parts[1])
        }
        return CSLName(family: value, given: nil)
    }
}
