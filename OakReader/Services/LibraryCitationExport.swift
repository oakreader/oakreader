import AppKit
import Foundation

extension LibraryStore {
    // MARK: - Citation Export

    /// Copy a formatted citation to the pasteboard.
    func copyCitation(_ item: LibraryItem, style: CitationStyle) {
        guard let csl = item.referenceMetadata?.cslItem else { return }
        let text: String
        switch style {
        case .apa: text = CitationFormatter.toAPA(csl: csl)
        case .mla: text = CitationFormatter.toMLA(csl: csl)
        case .chicago: text = CitationFormatter.toChicago(csl: csl)
        case .bibtex: text = CitationFormatter.toBibTeX(csl: csl)
        case .ris: text = CitationFormatter.toRIS(csl: csl)
        case .cslJson: text = CitationFormatter.toCSLJSON(csl: csl)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Export multiple items as BibTeX.
    func exportBibTeX(items: [LibraryItem]) -> String {
        items.compactMap { $0.referenceMetadata?.cslItem }
            .map { CitationFormatter.toBibTeX(csl: $0) }
            .joined(separator: "\n\n")
    }

    /// Export multiple items as RIS.
    func exportRIS(items: [LibraryItem]) -> String {
        items.compactMap { $0.referenceMetadata?.cslItem }
            .map { CitationFormatter.toRIS(csl: $0) }
            .joined(separator: "\n")
    }

    /// Export multiple items as CSL JSON array.
    func exportCSLJSON(items: [LibraryItem]) -> String {
        let cslItems = items.compactMap { $0.referenceMetadata?.cslItem }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cslItems),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

}
