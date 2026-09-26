import Foundation

/// Reference metadata, on its way to and from the core.
///
/// What remains here is the parsing that has no business in a catalog: reading
/// Zotero's free-text `extra` block, where a line like "DOI: 10.1000/x" stands
/// in for a CSL field. The rows themselves live in the core — see
/// `ReferenceCatalog`.
struct ReferenceService {
    /// An item's stored metadata, or nil when it has no citation.
    func fetchMetadata(forItemId itemId: String) async -> ReferenceMetadata? {
        guard let json = await ReferenceCatalog.metadata(forItemId: itemId) else { return nil }
        return ReferenceMetadata(jsonString: json)
    }

    /// Save an item's metadata. The core derives the indexed columns, renames
    /// the item from the citation and assigns a cite key if it had none.
    func saveMetadata(_ cslItem: CSLItem, forItemId itemId: String, extra: String? = nil) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let jsonString = String(data: try encoder.encode(cslItem), encoding: .utf8) else {
            throw ReferenceError.encodingFailed
        }
        try await ReferenceCatalog.save(cslJson: jsonString, forItemId: itemId, extra: extra)
    }

    // MARK: - Extra Field Parsing

    /// Parse `extra` for "Key: Value" lines and merge into CSL JSON (only fills empty fields).
    static func mergeExtraFields(_ extra: String, into csl: inout CSLItem) {
        let lines = extra.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[trimmed.startIndex..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            // Map known extra keys to CSL field keys
            if let cslKey = extraKeyToCSLField[key], csl[jsonKey: cslKey] == nil {
                csl[jsonKey: cslKey] = value
            }
        }
    }

    /// Mapping from extra field keys (lowercased) to CSL JSON wire keys.
    private static let extraKeyToCSLField: [String: String] = [
        "doi": "DOI",
        "isbn": "ISBN",
        "issn": "ISSN",
        "volume": "volume",
        "issue": "issue",
        "pages": "page",
        "publisher": "publisher",
        "language": "language",
    ]

}

enum ReferenceError: Error {
    case encodingFailed
}
