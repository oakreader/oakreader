import Foundation
import AppKit
import OakAgent

struct URLImportOptions {}

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
        let item: LibraryItem?
        if Self.audioExtensions.contains(ext) {
            item = await importAudioFile(from: sourceURL)
        } else {
            item = await MainActor.run { importFile(from: sourceURL) }
        }
        if item != nil {
            Analytics.capture("content_imported", properties: ["source": "file"])
        }
        return item
    }

    // MARK: - URL Imports

    /// Import a remote URL into the library.
    /// - PDF URLs are downloaded and imported as PDFs.
    /// - HTML pages are archived with monolith, converted to `content.md`, and imported as HTML documents.
    @discardableResult
    func importURL(_ sourceURL: URL, options: URLImportOptions = URLImportOptions()) async throws -> LibraryItem? {
        guard sourceURL.scheme?.lowercased().hasPrefix("http") == true else {
            throw URLImportError.invalidURL
        }

        if let existing = await MainActor.run(body: { store.findItem(bySourceURL: sourceURL) }) {
            return existing
        }

        let info = await remoteInfo(for: sourceURL)
        let imported: LibraryItem?
        if Self.isLikelyPDFURL(sourceURL, contentType: info.contentType) {
            imported = try await importRemotePDF(sourceURL, suggestedTitle: info.title)
        } else {
            imported = try await importRemoteWebPage(sourceURL, fallbackHTML: info.html, title: info.title)
        }
        if imported != nil {
            Analytics.capture("content_imported", properties: ["source": "url"])
        }
        return imported
    }

    // MARK: - Live Browser Bookmark

    /// Save the current live browser page as a *bookmark* (`.link`) rather than an
    /// offline HTML archive. Stores only the URL + a `content.md` (for AI/search),
    /// so reopening loads the page live in the browser instead of a static snapshot.
    /// `liveTitle`/`liveMarkdown` come from the rendered page (`LivePageBridge`),
    /// which captures SPA content a server-side fetch would miss.
    @discardableResult
    func importBrowserLink(_ sourceURL: URL, liveTitle: String?, liveMarkdown: String?) async -> LibraryItem? {
        guard sourceURL.scheme?.lowercased().hasPrefix("http") == true else { return nil }
        if let existing = await MainActor.run(body: { store.findItem(bySourceURL: sourceURL) }) {
            return existing
        }

        // Meta tags (og:title/og:image/description) live in the static head, so a
        // light fetch still enriches even SPA pages with a thumbnail + description.
        let info = await remoteInfo(for: sourceURL)
        let title = [liveTitle, info.title, sourceURL.host, sourceURL.absoluteString]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Untitled"
        let author = info.author ?? sourceURL.host ?? ""

        var thumbnailData: Data?
        if let thumbURL = info.thumbnailURL {
            var req = URLRequest(url: thumbURL)
            req.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
            thumbnailData = try? await URLSession.shared.data(for: req).0
        }

        let metadata = MediaMetadata(
            title: title,
            author: author,
            sourceURL: sourceURL,
            duration: nil,
            thumbnailURL: info.thumbnailURL,
            publishedAt: nil,
            description: info.description,
            embedType: "link"
        )

        let markdown = liveMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines)

        return await MainActor.run {
            importEmbed(.init(
                title: title,
                author: author,
                sourceURL: sourceURL,
                duration: nil,
                thumbnailData: thumbnailData,
                metadata: metadata,
                embedType: "link",
                contentMarkdown: (markdown?.isEmpty == false) ? markdown : nil
            ))
        }
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
        guard let monolithPath = ToolResolver.resolveFromInstalledSkills(name: "monolith") else {
            throw URLImportError.archiverUnavailable
        }
        let monolith = URL(fileURLWithPath: monolithPath)

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
        if let toolPath = ToolResolver.resolveFromInstalledSkills(name: "html-to-markdown") {
            if let result = try? await Self.runProcess(
                executableURL: URL(fileURLWithPath: toolPath),
                arguments: [htmlURL.path]
            ), result.exitCode == 0,
               !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return result.stdout
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

    struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Timeout for child processes (e.g. html-to-markdown, monolith).
    private static let processTimeout: TimeInterval = 30

    static func runProcess(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
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

            // Kill the process if it exceeds the timeout.
            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + processTimeout)
            timer.setEventHandler { process.terminate() }
            timer.resume()

            // Read both pipes concurrently BEFORE waitUntilExit to avoid
            // pipe buffer deadlock.
            var outData = Data()
            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                outData = stdout.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errData = stderr.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.wait()

            process.waitUntilExit()
            timer.cancel()

            return ProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(data: outData, encoding: .utf8) ?? "",
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }.value
    }
}
