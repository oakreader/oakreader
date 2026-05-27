import Foundation

extension ImportService {
    // MARK: - Embed Import

    struct EmbedImportInput {
        let title: String
        let author: String
        let sourceURL: URL
        let duration: Int?
        let thumbnailData: Data?
        let metadata: MediaMetadata
        var embedType: String = "youtube"
        var contentMarkdown: String?
    }

    /// Import an embed (YouTube or generic link) from Chrome extension payload.
    @discardableResult
    func importEmbed(_ input: EmbedImportInput) -> LibraryItem? {
        // Duplicate detection by source URL
        if let existing = store.findItem(bySourceURL: input.sourceURL) {
            return existing
        }

        // All embed clips are bookmarks/links (loaded on demand).
        let resolvedContentType: ContentType = .link

        let docId = UUID()
        let attId = UUID()
        let itemStorageKey = CatalogDatabase.generateStorageKey()
        let attStorageKey = CatalogDatabase.generateStorageKey()
        let docDir = CatalogDatabase.documentDirectory(storageKey: itemStorageKey)
        let attDir = CatalogDatabase.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)

        do {
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)

            // Write metadata.json to attachment directory
            let metadataURL = CatalogDatabase.attachmentMetadataURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
            let encoded = try JSONEncoder().encode(input.metadata)
            try encoded.write(to: metadataURL, options: .atomic)

            // Write thumbnail as cover to attachment directory
            if let thumbnailData = input.thumbnailData {
                let coverURL = CatalogDatabase.attachmentCoverURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
                try thumbnailData.write(to: coverURL, options: .atomic)
            }

            // Generate embed.html for non-YouTube types (link bookmarks)
            if input.embedType != "youtube" {
                let embedHTML = Self.generateLinkEmbedHTML(metadata: input.metadata)
                let embedHTMLURL = attDir.appendingPathComponent("embed.html")
                try embedHTML.write(to: embedHTMLURL, atomically: true, encoding: .utf8)
            }

            // Save article markdown for AI chat context
            if let md = input.contentMarkdown,
               !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let mdURL = attDir.appendingPathComponent("content.md")
                try md.write(to: mdURL, atomically: true, encoding: .utf8)
            }
        } catch {
            Log.error(Log.importer, "Failed to import embed: \(error)")
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        let now = Date().iso8601String
        let itemRecord = ItemRecord(
            id: docId.uuidString,
            userId: localUserId,
            storageKey: itemStorageKey,
            title: input.title,
            author: input.author,
            lastOpenedAt: nil,
            syncStatus: SyncStatus.local.rawValue,
            createdAt: now,
            updatedAt: now
        )

        let attRecord = AttachmentRecord(
            id: attId.uuidString,
            itemId: docId.uuidString,
            storageKey: attStorageKey,
            fileName: "metadata.json",
            contentType: resolvedContentType.rawValue,
            linkMode: LinkMode.linkedURL.rawValue,
            sourceURL: input.sourceURL.absoluteString,
            fileSize: 0,
            pageCount: input.duration ?? 0,
            isPrimary: true,
            createdAt: now,
            updatedAt: now
        )

        guard let item = store.insertItem(itemRecord, attachment: attRecord) else {
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        // Auto-create reference metadata
        let cslType: String
        switch input.embedType {
        case "link": cslType = "webpage"
        default: cslType = "motion_picture"
        }
        var csl = CSLItem(type: cslType)
        csl.title = input.title
        if !input.author.isEmpty {
            csl.author = [CSLName(family: input.author, given: nil)]
        }
        csl.URL = input.sourceURL.absoluteString
        try? referenceService.saveMetadata(csl, forItemId: docId.uuidString)
        store.invalidate()

        // Full-text search index (FTS5)
        if let service = ftsIndexService {
            Task {
                await service.indexItem(
                    itemId: docId.uuidString,
                    contentType: resolvedContentType.rawValue,
                    storageKey: itemStorageKey,
                    attStorageKey: attStorageKey,
                    fileName: "metadata.json"
                )
            }
        }

        return item
    }

    // MARK: - Embed HTML Generation

    static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Generate a styled HTML bookmark card for a generic link.
    static func generateLinkEmbedHTML(metadata: MediaMetadata) -> String {
        let title = escapeHTML(metadata.title)
        let author = escapeHTML(metadata.author)
        let description = escapeHTML(metadata.description ?? "")
        let sourceURL = escapeHTML(metadata.sourceURL.absoluteString)
        let domain = metadata.sourceURL.host ?? ""
        let escapedDomain = escapeHTML(domain)
        let initial = domain.first.map { String($0).uppercased() } ?? "W"

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          body {
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
            background: #1a1a1a;
            color: #e7e9ea;
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            padding: 40px;
          }
          .card {
            background: #16181c;
            border: 1px solid #2f3336;
            border-radius: 16px;
            padding: 24px;
            max-width: 520px;
            width: 100%;
          }
          .header {
            display: flex;
            align-items: center;
            gap: 12px;
            margin-bottom: 16px;
          }
          .favicon {
            width: 32px;
            height: 32px;
            border-radius: 8px;
            background: #2f3336;
            display: flex;
            align-items: center;
            justify-content: center;
            font-weight: 700;
            font-size: 16px;
            color: #71767b;
            flex-shrink: 0;
          }
          .domain {
            color: #71767b;
            font-size: 13px;
          }
          .title {
            font-weight: 700;
            font-size: 17px;
            line-height: 1.3;
            margin-bottom: 8px;
          }
          .description {
            font-size: 14px;
            line-height: 1.5;
            color: #a0a4a8;
            margin-bottom: 16px;
            display: -webkit-box;
            -webkit-line-clamp: 4;
            -webkit-box-orient: vertical;
            overflow: hidden;
          }
          .author {
            font-size: 13px;
            color: #71767b;
            margin-bottom: 16px;
          }
          .source {
            border-top: 1px solid #2f3336;
            padding-top: 12px;
          }
          .source a {
            color: #1d9bf0;
            text-decoration: none;
            font-size: 13px;
          }
        </style>
        </head>
        <body>
        <div class="card">
          <div class="header">
            <div class="favicon">\(escapeHTML(initial))</div>
            <div class="domain">\(escapedDomain)</div>
          </div>
          <div class="title">\(title)</div>
          \(description.isEmpty ? "" : "<div class=\"description\">\(description)</div>")
          \(author.isEmpty ? "" : "<div class=\"author\">\(author)</div>")
          <div class="source">
            <a href="\(sourceURL)">Open link</a>
          </div>
        </div>
        </body>
        </html>
        """
    }

}
