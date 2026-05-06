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

        // Build href-to-spine-index lookup for TOC resolution
        var hrefToSpineIndex: [String: Int] = [:]
        for (index, item) in resolved.enumerated() {
            // Store both with and without fragment
            hrefToSpineIndex[item.path] = index
            // Also store the filename without directory prefix for flexible matching
            let fileName = (item.path as NSString).lastPathComponent
            if hrefToSpineIndex[fileName] == nil {
                hrefToSpineIndex[fileName] = index
            }
        }

        self.tableOfContents = EPUBDocument.buildTOC(
            from: document.tableOfContents,
            hrefLookup: hrefToSpineIndex
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
        hrefLookup: [String: Int]
    ) -> [EPUBTOCEntry] {
        guard let subTable = toc.subTable else { return [] }
        return subTable.map { buildTOCEntry(from: $0, hrefLookup: hrefLookup) }
    }

    private static func buildTOCEntry(
        from toc: EPUBTableOfContents,
        hrefLookup: [String: Int]
    ) -> EPUBTOCEntry {
        let href = toc.item
        var spineIndex: Int?

        if let href {
            // Strip fragment identifier for spine lookup
            let basePath = href.components(separatedBy: "#").first ?? href
            spineIndex = hrefLookup[basePath]
            if spineIndex == nil {
                // Try filename-only match
                let fileName = (basePath as NSString).lastPathComponent
                spineIndex = hrefLookup[fileName]
            }
        }

        let children: [EPUBTOCEntry]
        if let subTable = toc.subTable {
            children = subTable.map { buildTOCEntry(from: $0, hrefLookup: hrefLookup) }
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
}
