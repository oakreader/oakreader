import Foundation

extension ImportService {
    // MARK: - Embed Import

    struct EmbedImportInput {
        let title: String
        let author: String
        let sourceURL: URL
        let duration: Int?
        let thumbnailData: Data?
        let transcript: String?
        let metadata: MediaMetadata
        var embedType: String = "youtube"
    }

    /// Import an embed (YouTube, Twitter, or generic link) from Chrome extension payload.
    @discardableResult
    func importEmbed(_ input: EmbedImportInput) -> LibraryItem? {
        // Duplicate detection by source URL
        if let existing = store.items.first(where: { $0.sourceURL == input.sourceURL }) {
            return existing
        }

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

            // Write transcript to attachment directory
            if let transcript = input.transcript, !transcript.isEmpty {
                let transcriptURL = CatalogDatabase.attachmentTranscriptURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
                try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
            }

            // Write thumbnail as cover to attachment directory
            if let thumbnailData = input.thumbnailData {
                let coverURL = CatalogDatabase.attachmentCoverURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
                try thumbnailData.write(to: coverURL, options: .atomic)
            }

            // Generate embed.html for non-YouTube types (tweets, links)
            if input.embedType != "youtube" {
                let embedHTML: String
                if input.embedType == "twitter" {
                    embedHTML = Self.generateTweetEmbedHTML(metadata: input.metadata)
                } else {
                    embedHTML = Self.generateLinkEmbedHTML(metadata: input.metadata)
                }
                let embedHTMLURL = attDir.appendingPathComponent("embed.html")
                try embedHTML.write(to: embedHTMLURL, atomically: true, encoding: .utf8)
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
            attachmentType: ItemType.embed.rawValue,
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
        case "twitter": cslType = "post"
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

        // Semantic index for vector search
        if let service = semanticIndexService {
            Task {
                await service.indexItem(
                    itemId: docId.uuidString,
                    attachmentType: ItemType.embed.rawValue,
                    storageKey: itemStorageKey,
                    attStorageKey: attStorageKey,
                    fileName: "metadata.json"
                )
            }
        }

        // Auto-generate chapters and highlights for YouTube embeds
        if input.embedType == "youtube" {
            let hasTranscript = input.transcript != nil && !input.transcript!.isEmpty
            Task {
                let service = ChapterGenerationService()
                // Generate structural chapters (native YouTube or AI sections)
                await service.run(
                    itemStorageKey: itemStorageKey,
                    attachmentStorageKey: attStorageKey,
                    sourceURL: input.sourceURL,
                    duration: input.duration,
                    transcriptAlreadyExists: hasTranscript,
                    mode: .chapters
                )
                // Generate AI highlights
                await service.run(
                    itemStorageKey: itemStorageKey,
                    attachmentStorageKey: attStorageKey,
                    sourceURL: input.sourceURL,
                    duration: input.duration,
                    transcriptAlreadyExists: hasTranscript,
                    tryNativeChapters: false,
                    mode: .highlights
                )
            }
        }

        return item
    }

    // MARK: - Embed HTML Generation

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Generate a styled HTML card for a tweet / X post.
    static func generateTweetEmbedHTML(metadata: MediaMetadata) -> String {
        let title = escapeHTML(metadata.title)
        let author = escapeHTML(metadata.author)
        let description = escapeHTML(metadata.description ?? "")
        let sourceURL = escapeHTML(metadata.sourceURL.absoluteString)
        let initial = author.first.map(String.init) ?? "X"

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
          .avatar {
            width: 40px;
            height: 40px;
            border-radius: 50%;
            background: #1d9bf0;
            display: flex;
            align-items: center;
            justify-content: center;
            font-weight: 700;
            font-size: 18px;
            color: white;
            flex-shrink: 0;
          }
          .author-info { flex: 1; min-width: 0; }
          .author-name {
            font-weight: 700;
            font-size: 15px;
            white-space: nowrap;
            overflow: hidden;
            text-overflow: ellipsis;
          }
          .author-handle {
            color: #71767b;
            font-size: 14px;
          }
          .x-logo {
            width: 24px;
            height: 24px;
            flex-shrink: 0;
          }
          .content {
            font-size: 15px;
            line-height: 1.5;
            white-space: pre-wrap;
            word-wrap: break-word;
            margin-bottom: 16px;
          }
          .media {
            margin-bottom: 16px;
          }
          .media img {
            width: 100%;
            border-radius: 12px;
            display: block;
          }
          .source {
            color: #71767b;
            font-size: 13px;
            border-top: 1px solid #2f3336;
            padding-top: 12px;
          }
          .source a {
            color: #1d9bf0;
            text-decoration: none;
          }
        </style>
        </head>
        <body>
        <div class="card">
          <div class="header">
            <div class="avatar">\(escapeHTML(initial))</div>
            <div class="author-info">
              <div class="author-name">\(title)</div>
              <div class="author-handle">\(author)</div>
            </div>
            <svg class="x-logo" viewBox="0 0 24 24" fill="#e7e9ea">
              <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99
              21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"/>
            </svg>
          </div>
          <div class="content">\(description)</div>
          <div class="media"><img src="cover.webp" onerror="this.parentElement.style.display='none'"></div>
          <div class="source">
            <a href="\(sourceURL)">View on X</a>
          </div>
        </div>
        </body>
        </html>
        """
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
