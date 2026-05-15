import Foundation
import AppKit

struct URLImportOptions {
    var preferEmbedForMedia: Bool = true
}

enum URLImportError: LocalizedError {
    case invalidURL
    case downloadFailed(String)
    case invalidPDFDownload
    case archiverUnavailable
    case archiverFailed(String)
    case importFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .invalidPDFDownload:
            return "Downloaded content is not a valid PDF"
        case .archiverUnavailable:
            return "monolith is not installed. Install it with `brew install monolith`."
        case .archiverFailed(let message):
            return "Web page failed: \(message)"
        case .importFailed:
            return "Import failed"
        }
    }
}

extension ImportService {
    // MARK: - Local Files

    @discardableResult
    func importFile(from sourceURL: URL) -> LibraryItem? {
        let ext = sourceURL.pathExtension.lowercased()
        if ext == "html" || ext == "htm" {
            return importHTML(from: sourceURL)
        } else if ext == "md" || ext == "markdown" {
            return importMarkdown(from: sourceURL)
        } else if ext == "pdf" {
            return importPDF(from: sourceURL)
        }
        return nil
    }

    /// Import a local file, including audio. Returns the item asynchronously for types that need it.
    @discardableResult
    func importFileAsync(from sourceURL: URL) async -> LibraryItem? {
        let ext = sourceURL.pathExtension.lowercased()
        if Self.audioExtensions.contains(ext) {
            return await importAudioFile(from: sourceURL)
        }
        return await MainActor.run { importFile(from: sourceURL) }
    }

    // MARK: - URL Imports

    /// Import a remote URL into the library.
    /// - PDF URLs are downloaded and imported as PDFs.
    /// - HTML pages are archived with monolith, converted to `content.md`, and imported as HTML documents.
    /// - YouTube/X links use the existing embed importer when possible.
    @discardableResult
    func importURL(_ sourceURL: URL, options: URLImportOptions = URLImportOptions()) async throws -> LibraryItem? {
        guard sourceURL.scheme?.lowercased().hasPrefix("http") == true else {
            throw URLImportError.invalidURL
        }

        if let existing = await MainActor.run(body: { store.items.first(where: { $0.sourceURL == sourceURL }) }) {
            return existing
        }

        if options.preferEmbedForMedia, Self.isMediaEmbedURL(sourceURL) {
            return try await importEmbedURL(sourceURL)
        }

        let info = await remoteInfo(for: sourceURL)
        if Self.isLikelyPDFURL(sourceURL, contentType: info.contentType) {
            return try await importRemotePDF(sourceURL, suggestedTitle: info.title)
        }

        return try await importRemoteWebPage(sourceURL, fallbackHTML: info.html, title: info.title)
    }

    // MARK: - PDF URL Import

    private func importRemotePDF(_ sourceURL: URL, suggestedTitle: String?) async throws -> LibraryItem? {
        var request = URLRequest(url: sourceURL)
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")

        let (tempDownloadURL, response): (URL, URLResponse)
        do {
            (tempDownloadURL, response) = try await URLSession.shared.download(for: request)
        } catch {
            throw URLImportError.downloadFailed(error.localizedDescription)
        }

        let data = try Data(contentsOf: tempDownloadURL, options: .mappedIfSafe)
        guard data.count >= 4,
              String(data: data.prefix(4), encoding: .ascii) == "%PDF" else {
            throw URLImportError.invalidPDFDownload
        }

        let filename = Self.remoteFileName(
            from: sourceURL,
            response: response,
            fallbackTitle: suggestedTitle,
            extension: "pdf"
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_" + filename)
        try data.write(to: tempURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let item = await MainActor.run { importPDF(from: tempURL) }
        guard let item else { throw URLImportError.importFailed }
        return item
    }

    // MARK: - HTML URL Import

    private func importRemoteWebPage(_ sourceURL: URL, fallbackHTML: String?, title: String?) async throws -> LibraryItem? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OakReaderURLImport_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileName = Self.sanitizeFileName(title ?? sourceURL.host ?? "webpage") + ".html"
        let htmlURL = tempDir.appendingPathComponent(fileName)

        do {
            try await archiveWithMonolith(sourceURL, outputURL: htmlURL)
        } catch URLImportError.archiverUnavailable {
            if let fallbackHTML, !fallbackHTML.isEmpty {
                try fallbackHTML.write(to: htmlURL, atomically: true, encoding: .utf8)
            } else {
                throw URLImportError.archiverUnavailable
            }
        } catch {
            if let fallbackHTML, !fallbackHTML.isEmpty {
                try fallbackHTML.write(to: htmlURL, atomically: true, encoding: .utf8)
            } else {
                throw error
            }
        }

        let markdown = await markdownFromHTML(htmlURL: htmlURL)

        let item = await MainActor.run {
            importHTML(
                from: htmlURL,
                originalPageURL: sourceURL,
                title: title,
                contentMarkdown: markdown
            )
        }
        guard let item else { throw URLImportError.importFailed }
        return item
    }

    private func archiveWithMonolith(_ sourceURL: URL, outputURL: URL) async throws {
        guard let monolith = Self.findExecutable(named: "monolith") else {
            throw URLImportError.archiverUnavailable
        }

        let result = try await Self.runProcess(
            executableURL: monolith,
            arguments: [
                "-I",      // isolate archived page from the network
                "-e",      // keep snapshot even when some resources fail
                "-q",
                "-t", "60",
                "-u", Self.browserUserAgent,
                "-o", outputURL.path,
                sourceURL.absoluteString
            ]
        )

        guard result.exitCode == 0, FileManager.default.fileExists(atPath: outputURL.path) else {
            throw URLImportError.archiverFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
    }

    private func markdownFromHTML(htmlURL: URL) async -> String? {
        if let pandoc = Self.findExecutable(named: "pandoc") {
            let mdURL = htmlURL.deletingPathExtension().appendingPathExtension("md")
            if let result = try? await Self.runProcess(
                executableURL: pandoc,
                arguments: [htmlURL.path, "-f", "html", "-t", "gfm", "--wrap=none", "-o", mdURL.path]
            ), result.exitCode == 0,
               let markdown = try? String(contentsOf: mdURL, encoding: .utf8),
               !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return markdown
            }
        }

        guard let data = try? Data(contentsOf: htmlURL),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              ) else {
            return nil
        }
        return attributed.string
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: - Embed URL Import

    private func importEmbedURL(_ sourceURL: URL) async throws -> LibraryItem? {
        let info = await remoteInfo(for: sourceURL)
        let title = info.title ?? sourceURL.host ?? sourceURL.absoluteString
        let author = info.author ?? ""
        let embedType = Self.detectEmbedType(from: sourceURL)
        let metadata = MediaMetadata(
            title: title,
            author: author,
            sourceURL: sourceURL,
            duration: nil,
            thumbnailURL: info.thumbnailURL,
            publishedAt: nil,
            description: info.description,
            embedType: embedType
        )

        let thumbnailData: Data?
        if let thumbnailURL = info.thumbnailURL {
            thumbnailData = try? await URLSession.shared.data(from: thumbnailURL).0
        } else {
            thumbnailData = nil
        }

        let item = await MainActor.run {
            importEmbed(.init(
                title: title,
                author: author,
                sourceURL: sourceURL,
                duration: nil,
                thumbnailData: thumbnailData,
                transcript: nil,
                metadata: metadata,
                embedType: embedType
            ))
        }
        guard let item else { throw URLImportError.importFailed }
        return item
    }

    // MARK: - URL Metadata

    private struct RemoteInfo {
        var contentType: String?
        var html: String?
        var title: String?
        var author: String?
        var description: String?
        var thumbnailURL: URL?
    }

    private func remoteInfo(for url: URL) async -> RemoteInfo {
        var contentType: String?

        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 12
        head.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        if let (_, response) = try? await URLSession.shared.data(for: head),
           let http = response as? HTTPURLResponse {
            contentType = http.value(forHTTPHeaderField: "Content-Type")
        }

        // Only fetch a body for likely HTML pages so we can get title/metadata and have a fallback.
        guard !Self.isLikelyPDFURL(url, contentType: contentType) else {
            return RemoteInfo(contentType: contentType)
        }

        var get = URLRequest(url: url)
        get.timeoutInterval = 20
        get.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: get) else {
            return RemoteInfo(contentType: contentType)
        }

        if let http = response as? HTTPURLResponse {
            contentType = http.value(forHTTPHeaderField: "Content-Type") ?? contentType
        }

        let html = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let html else {
            return RemoteInfo(contentType: contentType)
        }

        return RemoteInfo(
            contentType: contentType,
            html: html,
            title: Self.extractHTMLTitle(html)
                ?? extractHTMLMetaContent(html, property: "og:title")
                ?? extractHTMLMetaContent(html, name: "twitter:title"),
            author: extractHTMLMetaContent(html, name: "author")
                ?? extractHTMLMetaContent(html, property: "article:author"),
            description: extractHTMLMetaContent(html, property: "og:description")
                ?? extractHTMLMetaContent(html, name: "description")
                ?? extractHTMLMetaContent(html, name: "twitter:description"),
            thumbnailURL: Self.resolveURL(
                extractHTMLMetaContent(html, property: "og:image")
                    ?? extractHTMLMetaContent(html, name: "twitter:image"),
                relativeTo: url
            )
        )
    }

    private static func isLikelyPDFURL(_ url: URL, contentType: String?) -> Bool {
        if url.pathExtension.lowercased() == "pdf" { return true }
        return contentType?.lowercased().contains("application/pdf") == true
    }

    private static func isMediaEmbedURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.contains("youtube.com")
            || host.contains("youtu.be")
            || host.contains("x.com")
            || host.contains("twitter.com")
    }

    private static func detectEmbedType(from url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("youtube.com") || host.contains("youtu.be") { return "youtube" }
        if host.contains("x.com") || host.contains("twitter.com") { return "twitter" }
        return "link"
    }

    private static func extractHTMLTitle(_ html: String) -> String? {
        guard let range = html.range(of: "(?is)<title[^>]*>(.*?)</title>", options: .regularExpression) else {
            return nil
        }
        var title = String(html[range])
        title = title.replacingOccurrences(of: "(?is)</?title[^>]*>", with: "", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func resolveURL(_ string: String?, relativeTo baseURL: URL) -> URL? {
        guard let string, !string.isEmpty else { return nil }
        return URL(string: string, relativeTo: baseURL)?.absoluteURL
    }

    private static func remoteFileName(from url: URL, response: URLResponse, fallbackTitle: String?, extension ext: String) -> String {
        if let suggested = response.suggestedFilename, !suggested.isEmpty {
            return sanitizeFileName(suggested.hasSuffix(".\(ext)") ? suggested : "\(suggested).\(ext)")
        }
        if !url.lastPathComponent.isEmpty, url.lastPathComponent.lowercased().hasSuffix(".\(ext)") {
            return sanitizeFileName(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
        }
        let fallback = fallbackTitle ?? (url.deletingPathExtension().lastPathComponent.isEmpty
            ? "download"
            : url.deletingPathExtension().lastPathComponent)
        return sanitizeFileName(fallback) + ".\(ext)"
    }

    private static func sanitizeFileName(_ input: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = input.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(180))
    }

    private static let browserUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    // MARK: - Process Helpers

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func findExecutable(named name: String) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func runProcess(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory()
            ]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let outData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            return ProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }.value
    }
}
