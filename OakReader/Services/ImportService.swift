import Foundation
import PDFKit
import AppKit
import CommonCrypto

/// Handles PDF and web snapshot import: copy to managed storage, extract metadata, generate cover, insert into DB.
final class ImportService {
    let store: LibraryStore
    let coverService: LibraryCoverService
    let referenceService: ReferenceService

    init(store: LibraryStore, coverService: LibraryCoverService, referenceService: ReferenceService) {
        self.store = store
        self.coverService = coverService
        self.referenceService = referenceService
    }

    // MARK: - Import

    /// Import a PDF from any URL into managed storage.
    /// Returns the library item if successful, or the existing item if already imported.
    @discardableResult
    func importPDF(from sourceURL: URL) -> LibraryItem? {
        // Duplicate detection: hash first 64KB
        if let hash = hashPrefix(of: sourceURL),
           let existing = findByHash(hash) {
            return existing
        }

        // Check if already imported by filename (fallback)
        if let existing = store.findItem(byFileName: sourceURL.lastPathComponent) {
            return existing
        }

        let docId = UUID()
        let attId = UUID()
        let itemStorageKey = CatalogDatabase.generateStorageKey()
        let attStorageKey = CatalogDatabase.generateStorageKey()
        let docDir = CatalogDatabase.documentDirectory(storageKey: itemStorageKey)
        let attDir = CatalogDatabase.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
        let destURL = CatalogDatabase.attachmentFileURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey, fileName: sourceURL.lastPathComponent)

        do {
            // Create item directory and subdirectories
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)
            let sessionsDir = CatalogDatabase.documentSessionsDirectory(storageKey: itemStorageKey)
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

            // Copy PDF to attachment directory
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            Log.error(Log.importer, "Failed to copy PDF: \(error)")
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        // Extract metadata
        var title = sourceURL.deletingPathExtension().lastPathComponent
        var author = ""
        var pageCount = 0
        var webSourceURL: URL?

        if let pdfDoc = PDFDocument(url: destURL) {
            pageCount = pdfDoc.pageCount
            if let t = pdfDoc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !t.isEmpty {
                title = t
            }
            if let a = pdfDoc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String {
                author = a
            }
            webSourceURL = extractWebSourceURL(from: pdfDoc)
        }

        // File size
        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }

        // Insert into DB
        let now = Date().iso8601String
        let itemRecord = ItemRecord(
            id: docId.uuidString,
            userId: localUserId,
            storageKey: itemStorageKey,
            title: title,
            author: author,
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
            attachmentType: ItemType.pdf.rawValue,
            sourceURL: webSourceURL?.absoluteString,
            fileSize: fileSize,
            pageCount: pageCount,
            isPrimary: true,
            createdAt: now,
            updatedAt: now
        )

        guard let item = store.insertItem(itemRecord, attachment: attRecord) else {
            try? FileManager.default.removeItem(at: docDir)
            return nil
        }

        // Generate cover thumbnail asynchronously
        Task {
            if let coverData = await coverService.generateCover(for: destURL) {
                await MainActor.run {
                    store.updateCover(item, imageData: coverData)
                }
            }
        }

        // Auto-extract DOI and fetch reference metadata
        Task {
            await autoExtractReference(itemId: docId.uuidString, pdfURL: destURL, title: title, author: author, webSourceURL: webSourceURL)
        }

        return item
    }

    // MARK: - Web Snapshot Import

    /// Import an HTML web snapshot into managed storage.
    @discardableResult
    func importWebSnapshot(from sourceURL: URL, originalPageURL: URL? = nil, title: String? = nil) -> LibraryItem? {
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
        let attDir = CatalogDatabase.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
        let destURL = CatalogDatabase.attachmentFileURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey, fileName: sourceURL.lastPathComponent)

        do {
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)
            let sessionsDir = CatalogDatabase.documentSessionsDirectory(storageKey: itemStorageKey)
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

            try FileManager.default.copyItem(at: sourceURL, to: destURL)
        } catch {
            Log.error(Log.importer, "Failed to copy HTML snapshot: \(error)")
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
            attachmentType: ItemType.webSnapshot.rawValue,
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

        // Generate cover thumbnail asynchronously
        Task {
            if let coverData = await coverService.generateWebSnapshotCover(for: destURL) {
                await MainActor.run {
                    store.updateCover(item, imageData: coverData)
                }
            }
        }

        return item
    }

    // MARK: - Embed Import

    /// Import an embed (YouTube, Twitter, or generic link) from Chrome extension payload.
    @discardableResult
    func importEmbed(
        title: String,
        author: String,
        sourceURL: URL,
        duration: Int?,
        thumbnailData: Data?,
        transcript: String?,
        metadata: MediaMetadata,
        embedType: String = "youtube"
    ) -> LibraryItem? {
        // Duplicate detection by source URL
        if let existing = store.items.first(where: { $0.sourceURL == sourceURL }) {
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
            let sessionsDir = CatalogDatabase.documentSessionsDirectory(storageKey: itemStorageKey)
            try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

            // Write metadata.json to attachment directory
            let metadataURL = CatalogDatabase.attachmentMetadataURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
            let encoded = try JSONEncoder().encode(metadata)
            try encoded.write(to: metadataURL, options: .atomic)

            // Write transcript to attachment directory
            if let transcript, !transcript.isEmpty {
                let transcriptURL = CatalogDatabase.attachmentTranscriptURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
                try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
            }

            // Write thumbnail as cover to attachment directory
            if let thumbnailData {
                let coverURL = CatalogDatabase.attachmentCoverURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
                try thumbnailData.write(to: coverURL, options: .atomic)
            }

            // Generate embed.html for non-YouTube types (tweets, links)
            if embedType != "youtube" {
                let embedHTML: String
                if embedType == "twitter" {
                    embedHTML = Self.generateTweetEmbedHTML(metadata: metadata)
                } else {
                    embedHTML = Self.generateLinkEmbedHTML(metadata: metadata)
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
            title: title,
            author: author,
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
            sourceURL: sourceURL.absoluteString,
            fileSize: 0,
            pageCount: duration ?? 0,
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
        switch embedType {
        case "twitter": cslType = "post"
        case "link": cslType = "webpage"
        default: cslType = "motion_picture"
        }
        var csl = CSLItem(type: cslType)
        csl.title = title
        if !author.isEmpty {
            csl.author = [CSLName(family: author, given: nil)]
        }
        csl.URL = sourceURL.absoluteString
        try? referenceService.saveMetadata(csl, forItemId: docId.uuidString)
        store.invalidate()

        // Auto-generate chapters and highlights for YouTube embeds
        if embedType == "youtube" {
            let hasTranscript = transcript != nil && !transcript!.isEmpty
            Task {
                let service = ChapterGenerationService()
                // Generate structural chapters (native YouTube or AI sections)
                await service.run(
                    itemStorageKey: itemStorageKey,
                    attachmentStorageKey: attStorageKey,
                    sourceURL: sourceURL,
                    duration: duration,
                    transcriptAlreadyExists: hasTranscript,
                    mode: .chapters
                )
                // Generate AI highlights
                await service.run(
                    itemStorageKey: itemStorageKey,
                    attachmentStorageKey: attStorageKey,
                    sourceURL: sourceURL,
                    duration: duration,
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
              <path d="M18.244 2.25h3.308l-7.227 8.26 8.502 11.24H16.17l-5.214-6.817L4.99 21.75H1.68l7.73-8.835L1.254 2.25H8.08l4.713 6.231zm-1.161 17.52h1.833L7.084 4.126H5.117z"/>
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

    // MARK: - Reference Extraction

    /// Extract DOI from PDF text and fetch metadata from CrossRef.
    /// Always creates reference metadata — falls back to basic document info if no DOI found.
    private func autoExtractReference(itemId: String, pdfURL: URL, title: String, author: String, webSourceURL: URL? = nil) async {
        if let doi = DOIExtractorService.extractDOI(from: pdfURL) {
            do {
                let cslItem = try await CrossRefService.fetchMetadata(doi: doi)
                try referenceService.saveMetadata(cslItem, forItemId: itemId)
                await MainActor.run { store.invalidate() }
                return
            } catch {
                Log.error(Log.importer, "CrossRef lookup failed for DOI \(doi): \(error)")
            }
        }

        // Fallback: create metadata from document info
        let isWebPrint = webSourceURL != nil
        var csl = CSLItem(type: isWebPrint ? "webpage" : "document")
        csl.title = title.isEmpty ? nil : title
        if !author.isEmpty {
            csl.author = [CSLName(family: author, given: nil)]
        }
        if let webSourceURL {
            csl.URL = webSourceURL.absoluteString
        }
        do {
            try referenceService.saveMetadata(csl, forItemId: itemId)
            await MainActor.run { store.invalidate() }
        } catch {
            Log.error(Log.importer, "Failed to create fallback reference metadata: \(error)")
        }
    }

    // MARK: - Web Source URL Extraction

    /// Browser user-agent substrings that indicate a PDF was printed from a web page.
    private static let browserCreatorPatterns = [
        "Mozilla", "Chrome", "Safari", "Firefox",
        "wkhtmltopdf", "Chromium", "HeadlessChrome",
        "Microsoft Print to PDF"
    ]

    /// Detect if a PDF was saved from a web browser and extract the original page URL.
    /// Checks the creator attribute for browser signatures, then scans the first page text for a URL.
    private func extractWebSourceURL(from pdfDoc: PDFDocument) -> URL? {
        guard let creator = pdfDoc.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String,
              Self.browserCreatorPatterns.contains(where: { creator.localizedCaseInsensitiveContains($0) })
        else { return nil }

        guard let firstPage = pdfDoc.page(at: 0),
              let text = firstPage.string
        else { return nil }

        // Find the first http(s) URL in the page text
        guard let range = text.range(of: "https?://[^\\s]+", options: .regularExpression) else { return nil }
        let urlString = String(text[range])
        return URL(string: urlString)
    }

    // MARK: - Duplicate Detection

    /// Hash the first 64KB of a file for duplicate detection.
    private func hashPrefix(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { handle.closeFile() }
        let data = handle.readData(ofLength: 65536)
        guard !data.isEmpty else { return nil }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Find a document with the same hash prefix.
    /// Checks existing PDFs in storage by hashing their first 64KB.
    private func findByHash(_ hash: String) -> LibraryItem? {
        for item in store.items {
            let pdfURL = item.fileURL
            if let existingHash = hashPrefix(of: pdfURL), existingHash == hash {
                return item
            }
        }
        return nil
    }
}
