import Foundation

extension ImportService {
    // MARK: - HTML Import

    /// Import an HTML document into managed storage.
    @discardableResult
    func importHTML(
        from sourceURL: URL,
        originalPageURL: URL? = nil,
        title: String? = nil,
        contentMarkdown: String? = nil
    ) -> LibraryItem? {
        // Duplicate detection
        if let hash = hashPrefix(of: sourceURL),
           let existing = findByHash(hash) {
            return existing
        }

        let docId = UUID()
        let attId = UUID()
        let itemStorageKey = CatalogDatabase.generateStorageKey()
        let attStorageKey = CatalogDatabase.generateStorageKey()
        let docDir = CatalogDatabase.documentDirectory(storageKey: itemStorageKey)
        let attDir = CatalogDatabase.attachmentDirectory(
            itemStorageKey: itemStorageKey,
            attachmentStorageKey: attStorageKey
        )
        let destURL = CatalogDatabase.attachmentFileURL(
            itemStorageKey: itemStorageKey,
            attachmentStorageKey: attStorageKey,
            fileName: sourceURL.lastPathComponent
        )

        do {
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)

            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            Log.error(Log.importer, "Failed to copy HTML document: \(error)")
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        // Extract title from HTML <title> tag if not provided
        var resolvedTitle = title ?? sourceURL.deletingPathExtension().lastPathComponent
        if title == nil, let htmlString = try? String(contentsOf: destURL, encoding: .utf8) {
            if let titleMatch = htmlString.range(of: "(?<=<title>)[^<]+", options: .regularExpression) {
                let extracted = String(htmlString[titleMatch]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !extracted.isEmpty {
                    resolvedTitle = extracted
                }
            }
        }

        // File size
        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }

        let now = Date().iso8601String
        let itemRecord = ItemRecord(
            id: docId.uuidString,
            userId: localUserId,
            storageKey: itemStorageKey,
            title: resolvedTitle,
            author: "",
            lastOpenedAt: nil,
            syncStatus: SyncStatus.local.rawValue,
            createdAt: now,
            updatedAt: now
        )

        let attRecord = AttachmentRecord(
            id: attId.uuidString,
            itemId: docId.uuidString,
            storageKey: attStorageKey,
            fileName: sourceURL.lastPathComponent,
            contentType: ContentType.html.rawValue,
            linkMode: LinkMode.importedURL.rawValue,
            sourceURL: originalPageURL?.absoluteString,
            fileSize: fileSize,
            pageCount: 1,
            isPrimary: true,
            createdAt: now,
            updatedAt: now
        )

        guard let item = store.insertItem(itemRecord, attachment: attRecord) else {
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        // Save extracted Markdown before full-text indexing starts so search prefers clean article text.
        if let contentMarkdown,
           !contentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let mdURL = item.fileURL.deletingLastPathComponent().appendingPathComponent("content.md")
            try? contentMarkdown.write(to: mdURL, atomically: true, encoding: .utf8)
        }

        // Auto-create reference metadata from HTML meta tags
        createHTMLMetadata(
            htmlURL: destURL,
            itemId: docId.uuidString,
            resolvedTitle: resolvedTitle,
            originalPageURL: originalPageURL
        )

        // Generate cover thumbnail asynchronously
        Task {
            if let coverData = await coverService.generateHTMLCover(for: destURL) {
                await MainActor.run {
                    store.updateCover(item, imageData: coverData)
                }
            }
        }

        // Full-text search index (FTS5)
        if let service = ftsIndexService {
            Task {
                await service.indexItem(
                    itemId: docId.uuidString,
                    contentType: ContentType.html.rawValue,
                    storageKey: itemStorageKey,
                    attStorageKey: attStorageKey,
                    fileName: sourceURL.lastPathComponent
                )
            }
        }

        return item
    }

    // MARK: - HTML Metadata Extraction

    private func createHTMLMetadata(
        htmlURL: URL,
        itemId: String,
        resolvedTitle: String,
        originalPageURL: URL?
    ) {
        guard let htmlString = try? String(contentsOf: htmlURL, encoding: .utf8) else { return }

        var csl = CSLItem(type: "webpage")
        csl.title = resolvedTitle

        // og:site_name → containerTitle
        if let siteName = extractHTMLMetaContent(htmlString, property: "og:site_name") {
            csl.containerTitle = siteName
        }

        // author / article:author → author
        if let authorName = extractHTMLMetaContent(htmlString, name: "author")
            ?? extractHTMLMetaContent(htmlString, property: "article:author") {
            csl.author = [CSLName(family: authorName, given: nil, literal: authorName)]
        }

        // article:published_time → issued
        if let pubTime = extractHTMLMetaContent(htmlString, property: "article:published_time") {
            let parts = pubTime.prefix(10).split(separator: "-").compactMap { Int($0) }
            if let year = parts.first {
                csl.issued = CSLDate(
                    year: year,
                    month: parts.count > 1 ? parts[1] : nil,
                    day: parts.count > 2 ? parts[2] : nil
                )
            }
        }

        // og:description / description → abstract
        if let desc = extractHTMLMetaContent(htmlString, property: "og:description")
            ?? extractHTMLMetaContent(htmlString, name: "description") {
            csl.abstract = desc
        }

        // original page URL
        if let pageURL = originalPageURL {
            csl.URL = pageURL.absoluteString
        }

        // og:type — detect "article" to potentially refine type
        if let ogType = extractHTMLMetaContent(htmlString, property: "og:type"),
           ogType.lowercased() == "article" {
            csl.type = "webpage" // still webpage, but could be used for heuristics
        }

        // Fallback issued date to now
        if csl.issued == nil {
            let cal = Calendar.current
            let now = Date()
            csl.issued = CSLDate(
                year: cal.component(.year, from: now),
                month: cal.component(.month, from: now),
                day: cal.component(.day, from: now)
            )
        }

        csl.accessed = {
            let cal = Calendar.current
            let now = Date()
            return CSLDate(
                year: cal.component(.year, from: now),
                month: cal.component(.month, from: now),
                day: cal.component(.day, from: now)
            )
        }()

        do {
            try referenceService.saveMetadata(csl, forItemId: itemId)
        } catch {
            Log.error(Log.importer, "Failed to save HTML reference metadata: \(error)")
        }
    }

    /// Extract content from `<meta property="..." content="...">` tags.
    func extractHTMLMetaContent(_ html: String, property: String) -> String? {
        // Match <meta property="og:..." content="..."> or <meta content="..." property="og:...">
        let patterns = [
            "<meta[^>]+property=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"'][^>]+content=[\"']([^\"']*)[\"']",
            "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+property=[\"']\(NSRegularExpression.escapedPattern(for: property))[\"']",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let value = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Extract content from `<meta name="..." content="...">` tags.
    func extractHTMLMetaContent(_ html: String, name: String) -> String? {
        let patterns = [
            "<meta[^>]+name=[\"']\(NSRegularExpression.escapedPattern(for: name))[\"'][^>]+content=[\"']([^\"']*)[\"']",
            "<meta[^>]+content=[\"']([^\"']*)[\"'][^>]+name=[\"']\(NSRegularExpression.escapedPattern(for: name))[\"']",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let range = Range(match.range(at: 1), in: html) {
                let value = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

}
