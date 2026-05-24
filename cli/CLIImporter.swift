import Foundation
import CommonCrypto
import PDFKit
import OakAgent

// MARK: - CLI Importer

struct CLIImporter {
    let db: CLIDatabase

    // MARK: - Storage Layout (mirrors CatalogStoragePaths)

    private static var storageDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader/storage", isDirectory: true)
    }

    private static func attachmentDirectory(itemStorageKey: String, attachmentStorageKey: String) -> URL {
        storageDirectory
            .appendingPathComponent(itemStorageKey, isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(attachmentStorageKey, isDirectory: true)
    }

    private static func attachmentFileURL(itemStorageKey: String, attachmentStorageKey: String, fileName: String) -> URL {
        attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attachmentStorageKey)
            .appendingPathComponent(fileName)
    }

    // MARK: - Key Generation (mirrors CatalogDatabase.generateStorageKey)

    static func generateStorageKey() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<8).map { _ in chars.randomElement()! })
    }

    // MARK: - Duplicate Detection (mirrors ImportService.hashPrefix)

    static func hashPrefix(of url: URL) -> String? {
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

    /// Check if a file with the same hash already exists in storage.
    func findDuplicate(of sourceURL: URL) throws -> CLIItem? {
        guard let hash = Self.hashPrefix(of: sourceURL) else { return nil }

        let paths = try db.findAttachmentPaths()
        for (itemStorageKey, attStorageKey, fileName) in paths {
            let fileURL = Self.attachmentFileURL(
                itemStorageKey: itemStorageKey,
                attachmentStorageKey: attStorageKey,
                fileName: fileName
            )
            if let existingHash = Self.hashPrefix(of: fileURL), existingHash == hash {
                // Find the item that owns this attachment
                let items = try db.fetchAllItems()
                return items.first(where: { $0.item.storageKey == itemStorageKey })?.item
            }
        }
        return nil
    }

    // MARK: - PDF Import

    struct ImportResult {
        let itemId: String
        let title: String
        let isDuplicate: Bool
    }

    func importPDF(from sourceURL: URL, title titleOverride: String? = nil) throws -> ImportResult {
        // Duplicate detection
        if let existing = try findDuplicate(of: sourceURL) {
            return ImportResult(itemId: existing.id, title: existing.title, isDuplicate: true)
        }

        let docId = UUID().uuidString
        let attId = UUID().uuidString
        let itemStorageKey = Self.generateStorageKey()
        let attStorageKey = Self.generateStorageKey()
        let attDir = Self.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
        let destURL = Self.attachmentFileURL(
            itemStorageKey: itemStorageKey,
            attachmentStorageKey: attStorageKey,
            fileName: sourceURL.lastPathComponent
        )

        // Create directories and copy file
        try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        // Extract metadata
        var title = titleOverride ?? sourceURL.deletingPathExtension().lastPathComponent
        var author = ""
        var pageCount = 0

        if let pdfDoc = PDFDocument(url: destURL) {
            pageCount = pdfDoc.pageCount
            if titleOverride == nil,
               let t = pdfDoc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !t.isEmpty {
                title = t
            }
            if let a = pdfDoc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String {
                author = a
            }
        }

        // File size
        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }

        try db.insertItem(.init(
            id: docId,
            storageKey: itemStorageKey,
            title: title,
            author: author,
            attachmentId: attId,
            attachmentStorageKey: attStorageKey,
            fileName: sourceURL.lastPathComponent,
            contentType: "pdf",
            sourceURL: nil,
            fileSize: fileSize,
            pageCount: pageCount
        ))

        return ImportResult(itemId: docId, title: title, isDuplicate: false)
    }

    // MARK: - HTML Import

    func importHTML(from sourceURL: URL, title titleOverride: String? = nil, sourcePageURL: String? = nil) throws -> ImportResult {
        // Duplicate detection
        if let existing = try findDuplicate(of: sourceURL) {
            return ImportResult(itemId: existing.id, title: existing.title, isDuplicate: true)
        }

        let docId = UUID().uuidString
        let attId = UUID().uuidString
        let itemStorageKey = Self.generateStorageKey()
        let attStorageKey = Self.generateStorageKey()
        let attDir = Self.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
        let destURL = Self.attachmentFileURL(
            itemStorageKey: itemStorageKey,
            attachmentStorageKey: attStorageKey,
            fileName: sourceURL.lastPathComponent
        )

        try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        // Extract title from <title> tag if not provided
        var title = titleOverride ?? sourceURL.deletingPathExtension().lastPathComponent
        if titleOverride == nil, let htmlString = try? String(contentsOf: destURL, encoding: .utf8) {
            if let titleMatch = htmlString.range(of: "(?<=<title>)[^<]+", options: .regularExpression) {
                let extracted = String(htmlString[titleMatch]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !extracted.isEmpty {
                    title = extracted
                }
            }
        }

        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }

        try db.insertItem(.init(
            id: docId,
            storageKey: itemStorageKey,
            title: title,
            author: "",
            attachmentId: attId,
            attachmentStorageKey: attStorageKey,
            fileName: sourceURL.lastPathComponent,
            contentType: "html",
            sourceURL: sourcePageURL,
            fileSize: fileSize,
            pageCount: 1
        ))

        // Generate content.md via html-to-markdown if available
        extractMarkdown(from: destURL, to: attDir)

        return ImportResult(itemId: docId, title: title, isDuplicate: false)
    }

    // MARK: - Markdown Import

    func importMarkdown(from sourceURL: URL, title titleOverride: String? = nil) throws -> ImportResult {
        // Duplicate detection
        if let existing = try findDuplicate(of: sourceURL) {
            return ImportResult(itemId: existing.id, title: existing.title, isDuplicate: true)
        }

        let docId = UUID().uuidString
        let attId = UUID().uuidString
        let itemStorageKey = Self.generateStorageKey()
        let attStorageKey = Self.generateStorageKey()
        let attDir = Self.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
        let destURL = Self.attachmentFileURL(
            itemStorageKey: itemStorageKey,
            attachmentStorageKey: attStorageKey,
            fileName: sourceURL.lastPathComponent
        )

        try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: destURL)

        // Extract title from first # heading
        var title = titleOverride ?? sourceURL.deletingPathExtension().lastPathComponent
        if titleOverride == nil, let mdString = try? String(contentsOf: destURL, encoding: .utf8) {
            let lines = mdString.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("# ") {
                    let heading = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    if !heading.isEmpty {
                        title = heading
                    }
                    break
                }
            }
        }

        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }

        try db.insertItem(.init(
            id: docId,
            storageKey: itemStorageKey,
            title: title,
            author: "",
            attachmentId: attId,
            attachmentStorageKey: attStorageKey,
            fileName: sourceURL.lastPathComponent,
            contentType: "markdown",
            sourceURL: nil,
            fileSize: fileSize,
            pageCount: 1
        ))

        return ImportResult(itemId: docId, title: title, isDuplicate: false)
    }

    // MARK: - URL Import

    func importURL(_ urlString: String, title: String? = nil) async throws -> ImportResult {
        guard let url = URL(string: urlString) else {
            throw ImportError.invalidURL(urlString)
        }

        if urlString.lowercased().hasSuffix(".pdf") {
            // Download PDF directly
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            let pdfURL = tempURL.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: tempURL, to: pdfURL)
            defer { try? FileManager.default.removeItem(at: pdfURL) }
            return try importPDF(from: pdfURL, title: title)
        } else {
            // Capture web page with monolith
            guard let monolithPath = ToolResolver.resolveFromInstalledSkills(name: "monolith") else {
                throw ImportError.monolithNotFound
            }

            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // Use domain + path slug for filename
            let slug = (url.host ?? "page").replacingOccurrences(of: ".", with: "_")
            let htmlFileName = "\(slug).html"
            let htmlPath = tempDir.appendingPathComponent(htmlFileName)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: monolithPath)
            process.arguments = [urlString, "-o", htmlPath.path]
            let pipe = Pipe()
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
                throw ImportError.monolithFailed(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            return try importHTML(from: htmlPath, title: title, sourcePageURL: urlString)
        }
    }

    // MARK: - Markdown Extraction

    /// If html-to-markdown is available, convert HTML to markdown and save as content.md.
    /// Silent no-op if html-to-markdown is not installed.
    /// Timeout in seconds for HTML-to-Markdown conversions.
    private static let conversionTimeout: TimeInterval = 30

    func extractMarkdown(from htmlURL: URL, to attachmentDir: URL) {
        guard let toolPath = ToolResolver.resolveFromInstalledSkills(name: "html-to-markdown") else { return }

        let mdURL = attachmentDir.appendingPathComponent("content.md")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = [htmlURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + Self.conversionTimeout)
            timer.setEventHandler { process.terminate() }
            timer.resume()

            // Read pipe data BEFORE waitUntilExit to avoid pipe buffer deadlock.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timer.cancel()

            guard process.terminationStatus == 0 else { return }
            guard !data.isEmpty else { return }
            try data.write(to: mdURL)
        } catch {
            // Silent failure — html-to-markdown is optional
        }
    }

}

// MARK: - Import Errors

enum ImportError: LocalizedError {
    case invalidURL(String)
    case monolithNotFound
    case monolithFailed(String)
    case fileNotFound(String)
    case unsupportedType(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .monolithNotFound:
            return "monolith is not installed. Install with: brew install monolith"
        case .monolithFailed(let msg):
            return "monolith failed: \(msg)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .unsupportedType(let ext):
            return "Unsupported file type: \(ext). Supported: .pdf, .html, .htm, .md, .markdown"
        }
    }
}
