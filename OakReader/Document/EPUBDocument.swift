import Foundation
import EPUBKit

/// Table of contents entry for sidebar display and navigation.
struct EPUBTOCEntry: Identifiable {
    let id: UUID
    let label: String
    /// Relative href to the content file (may include fragment, e.g. "chapter1.xhtml#section2").
    let href: String?
    /// Index into the spine array, resolved from href. Nil if unresolvable.
    let spineIndex: Int?
    let children: [EPUBTOCEntry]
}

/// Resolved spine item with its manifest path and media type.
struct EPUBResolvedSpineItem {
    let idref: String
    let path: String
    let linear: Bool
}

/// Lightweight data holder for EPUB files.
/// Not an NSDocument — EPUBs are read-only, no autosave needed.
final class EPUBDocument {
    let epubURL: URL
    let contentDirectory: URL
    let title: String
    let author: String
    let coverImageURL: URL?
    let spineItems: [EPUBResolvedSpineItem]
    let tableOfContents: [EPUBTOCEntry]
    let language: String?

    init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw OakReaderError.fileNotFound(url)
        }

        let document: EPUBKit.EPUBDocument
        do {
            document = try EPUBParser().parse(documentAt: url)
        } catch {
            throw OakReaderError.invalidEPUB("\(error.localizedDescription)")
        }

        self.epubURL = url
        self.contentDirectory = document.contentDirectory
        self.title = document.title ?? url.deletingPathExtension().lastPathComponent
        self.author = document.author ?? ""
        self.coverImageURL = document.cover
        self.language = document.metadata.language

        // Resolve spine items: map each spine idref to a manifest path
        var resolved: [EPUBResolvedSpineItem] = []
        for spineItem in document.spine.items {
            if let manifestItem = document.manifest.items[spineItem.idref] {
                resolved.append(EPUBResolvedSpineItem(
                    idref: spineItem.idref,
                    path: manifestItem.path,
                    linear: spineItem.linear
                ))
            }
        }
        self.spineItems = resolved

        // Build href-to-spine-index lookup for TOC resolution.
        // Store multiple key variants to handle path format mismatches between
        // the TOC (NCX src / EPUB3 nav href) and the OPF manifest href.
        var hrefToSpineIndex: [String: Int] = [:]
        for (index, item) in resolved.enumerated() {
            let path = item.path
            hrefToSpineIndex[path] = index
            // Percent-decoded variant
            if let decoded = path.removingPercentEncoding, decoded != path {
                hrefToSpineIndex[decoded] = index
            }
            // Filename-only variant for flexible matching
            let fileName = (path as NSString).lastPathComponent
            if hrefToSpineIndex[fileName] == nil {
                hrefToSpineIndex[fileName] = index
            }
            if let decodedName = fileName.removingPercentEncoding,
               decodedName != fileName,
               hrefToSpineIndex[decodedName] == nil {
                hrefToSpineIndex[decodedName] = index
            }
        }

        // Collect all spine paths for suffix matching fallback
        let spinePaths = resolved.map(\.path)

        self.tableOfContents = EPUBDocument.buildTOC(
            from: document.tableOfContents,
            hrefLookup: hrefToSpineIndex,
            spinePaths: spinePaths
        )
    }

    /// Full URL for a spine item's content file.
    func contentURL(for spineIndex: Int) -> URL? {
        guard spineIndex >= 0, spineIndex < spineItems.count else { return nil }
        return contentDirectory.appendingPathComponent(spineItems[spineIndex].path)
    }

    // MARK: - Private

    private static func buildTOC(
        from toc: EPUBTableOfContents,
        hrefLookup: [String: Int],
        spinePaths: [String]
    ) -> [EPUBTOCEntry] {
        guard let subTable = toc.subTable else { return [] }
        return subTable.map { buildTOCEntry(from: $0, hrefLookup: hrefLookup, spinePaths: spinePaths) }
    }

    private static func buildTOCEntry(
        from toc: EPUBTableOfContents,
        hrefLookup: [String: Int],
        spinePaths: [String]
    ) -> EPUBTOCEntry {
        let href = toc.item
        var spineIndex: Int?

        if let href {
            spineIndex = resolveSpineIndex(href: href, hrefLookup: hrefLookup, spinePaths: spinePaths)
        }

        let children: [EPUBTOCEntry]
        if let subTable = toc.subTable {
            children = subTable.map { buildTOCEntry(from: $0, hrefLookup: hrefLookup, spinePaths: spinePaths) }
        } else {
            children = []
        }

        return EPUBTOCEntry(
            id: UUID(),
            label: toc.label,
            href: href,
            spineIndex: spineIndex,
            children: children
        )
    }

    /// Resolve a TOC href to a spine index using multiple matching strategies.
    /// Handles mismatches between NCX/nav hrefs and manifest paths (different base dirs,
    /// percent-encoding, relative path prefixes).
    private static func resolveSpineIndex(
        href: String,
        hrefLookup: [String: Int],
        spinePaths: [String]
    ) -> Int? {
        // Strip fragment identifier
        let basePath = href.components(separatedBy: "#").first ?? href
        let cleanPath = basePath.replacingOccurrences(of: "./", with: "")

        // 1. Exact match
        if let idx = hrefLookup[cleanPath] { return idx }

        // 2. Percent-decoded match
        if let decoded = cleanPath.removingPercentEncoding, decoded != cleanPath {
            if let idx = hrefLookup[decoded] { return idx }
        }

        // 3. Filename-only match
        let fileName = (cleanPath as NSString).lastPathComponent
        if let idx = hrefLookup[fileName] { return idx }
        if let decodedName = fileName.removingPercentEncoding, decodedName != fileName {
            if let idx = hrefLookup[decodedName] { return idx }
        }

        // 4. Suffix match: the TOC href might be relative to a subdirectory
        //    (e.g., nav href "chapter1.xhtml" should match spine path "Text/chapter1.xhtml")
        for (index, spinePath) in spinePaths.enumerated() {
            if spinePath.hasSuffix("/\(cleanPath)") || spinePath == cleanPath {
                return index
            }
            // Also try: spine path might be a suffix of the TOC href
            // (e.g., href "../Text/chapter1.xhtml" should match spine path "Text/chapter1.xhtml")
            if cleanPath.hasSuffix("/\(spinePath)") {
                return index
            }
            // Percent-decoded comparison
            if let decodedSpine = spinePath.removingPercentEncoding {
                if decodedSpine.hasSuffix("/\(cleanPath)") || decodedSpine == cleanPath {
                    return index
                }
            }
        }

        // 5. Case-insensitive filename match as last resort
        let lowerFileName = fileName.lowercased()
        for (index, spinePath) in spinePaths.enumerated() {
            let spineFileName = (spinePath as NSString).lastPathComponent.lowercased()
            if spineFileName == lowerFileName {
                return index
            }
        }

        return nil
    }
}
