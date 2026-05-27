import Foundation
import PDFKit
import OakAgent

extension ImportService {
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
            // Create item directory and subdirectories
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)

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
            contentType: ContentType.pdf.rawValue,
            linkMode: LinkMode.importedFile.rawValue,
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

        // Extract structured markdown from PDF (for full-text indexing and CLI reading)
        if let service = ftsIndexService {
            Task {
                await extractPDFMarkdown(pdfURL: destURL, attachmentDir: attDir)
                await service.indexItem(
                    itemId: docId.uuidString,
                    contentType: ContentType.pdf.rawValue,
                    storageKey: itemStorageKey,
                    attStorageKey: attStorageKey,
                    fileName: sourceURL.lastPathComponent
                )
            }
        } else {
            Task { await extractPDFMarkdown(pdfURL: destURL, attachmentDir: attDir) }
        }

        return item
    }

    // MARK: - PDF Markdown Extraction

    /// If pdf-oxide is available, convert PDF to structured markdown and save as content.md.
    /// Silent no-op if pdf-oxide is not installed.
    private func extractPDFMarkdown(pdfURL: URL, attachmentDir: URL) async {
        guard let toolPath = ToolResolver.resolveFromInstalledSkills(name: "pdf-oxide") else { return }

        let mdURL = attachmentDir.appendingPathComponent("content.md")
        guard let result = try? await Self.runProcess(
            executableURL: URL(fileURLWithPath: toolPath),
            arguments: ["markdown", pdfURL.path]
        ), result.exitCode == 0,
           !result.stdout.isEmpty else {
            return
        }

        try? result.stdout.write(to: mdURL, atomically: true, encoding: .utf8)
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

}
