import AppKit
import Foundation
import OakAgent

/// Fetches a web page and extracts its content as clean markdown.
/// Uses the same HTML→Markdown pipeline as ImportService (html-to-markdown binary
/// with NSAttributedString fallback).
struct WebFetchTool: AgentTool, Sendable {
    let name = "fetch_web"
    let description = """
        Fetch a web page URL and extract its content as clean markdown. \
        Use after search_web to read the full content of a result, or to \
        fetch any URL the user provides. Returns the page title, extracted \
        markdown text, and metadata (author, description).
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "url": [
                    "type": "string",
                    "description": "The HTTP(S) URL to fetch",
                ],
                "max_chars": [
                    "type": "string",
                    "description": "Maximum characters to return (default: 20000)",
                ],
            ],
            "required": ["url"],
        ]
    }

    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolOutput {
        guard let urlString = input["url"], !urlString.isEmpty else {
            return .error("Missing required parameter: url")
        }
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return .error("Invalid URL. Must be an HTTP or HTTPS URL.")
        }

        let maxChars = min(max(Int(input["max_chars"] ?? "20000") ?? 20000, 1000), 50000)

        // Fetch the page
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else {
            return .error("Failed to fetch URL: \(urlString)")
        }

        guard let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        else {
            return .error("Could not decode response from: \(urlString)")
        }

        // Extract metadata
        let title = Self.extractTitle(html) ?? url.host ?? urlString
        let description = Self.extractMetaContent(html, property: "og:description")
            ?? Self.extractMetaContent(html, name: "description")
        let author = Self.extractMetaContent(html, name: "author")
            ?? Self.extractMetaContent(html, property: "article:author")

        // Convert to markdown
        let markdown = await convertToMarkdown(html: html, data: data)

        // Build output
        var output = "# \(title)\n"
        output += "URL: \(urlString)\n"
        if let author, !author.isEmpty {
            output += "Author: \(author)\n"
        }
        if let description, !description.isEmpty {
            output += "Description: \(description)\n"
        }
        output += "\n---\n\n"

        if let markdown, !markdown.isEmpty {
            output += markdown
        } else {
            output += "(Could not extract readable content from this page.)"
        }

        return .success(String(output.prefix(maxChars)))
    }

    // MARK: - HTML → Markdown

    private func convertToMarkdown(html: String, data: Data) async -> String? {
        // Tier 1: html-to-markdown binary via installed skills
        if let toolPath = ToolResolver.resolveFromInstalledSkills(name: "html-to-markdown") {
            let tempFile = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".html")
            do {
                try data.write(to: tempFile)
                defer { try? FileManager.default.removeItem(at: tempFile) }

                let result = try await Self.runProcess(
                    executableURL: URL(fileURLWithPath: toolPath),
                    arguments: [tempFile.path]
                )
                if result.exitCode == 0,
                   !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return result.stdout
                }
            } catch {
                // Fall through to tier 2
            }
        }

        // Tier 2: NSAttributedString fallback
        guard let attributed = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
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

    // MARK: - Metadata Extraction

    private static func extractTitle(_ html: String) -> String? {
        guard let range = html.range(
            of: "(?is)<title[^>]*>(.*?)</title>",
            options: .regularExpression
        ) else { return nil }
        var title = String(html[range])
        title = title.replacingOccurrences(
            of: "(?is)</?title[^>]*>", with: "", options: .regularExpression
        )
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func extractMetaContent(_ html: String, property: String) -> String? {
        // Match <meta property="..." content="..."> (attribute order may vary)
        let pattern = #"<meta\s+[^>]*property="\#(NSRegularExpression.escapedPattern(for: property))"[^>]*content="([^"]*)"[^>]*>"#
        let altPattern = #"<meta\s+[^>]*content="([^"]*)"[^>]*property="\#(NSRegularExpression.escapedPattern(for: property))"[^>]*>"#

        if let match = html.range(of: pattern, options: .regularExpression),
           let contentRange = html[match].range(of: #"content="([^"]*)""#, options: .regularExpression) {
            let raw = String(html[contentRange])
            let value = raw.replacingOccurrences(of: #"content=""#, with: "")
                .replacingOccurrences(of: "\"", with: "")
            return value.isEmpty ? nil : value
        }
        if let match = html.range(of: altPattern, options: .regularExpression),
           let contentRange = html[match].range(of: #"content="([^"]*)""#, options: .regularExpression) {
            let raw = String(html[contentRange])
            let value = raw.replacingOccurrences(of: #"content=""#, with: "")
                .replacingOccurrences(of: "\"", with: "")
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func extractMetaContent(_ html: String, name: String) -> String? {
        let pattern = #"<meta\s+[^>]*name="\#(NSRegularExpression.escapedPattern(for: name))"[^>]*content="([^"]*)"[^>]*>"#
        let altPattern = #"<meta\s+[^>]*content="([^"]*)"[^>]*name="\#(NSRegularExpression.escapedPattern(for: name))"[^>]*>"#

        if let match = html.range(of: pattern, options: .regularExpression),
           let contentRange = html[match].range(of: #"content="([^"]*)""#, options: .regularExpression) {
            let raw = String(html[contentRange])
            let value = raw.replacingOccurrences(of: #"content=""#, with: "")
                .replacingOccurrences(of: "\"", with: "")
            return value.isEmpty ? nil : value
        }
        if let match = html.range(of: altPattern, options: .regularExpression),
           let contentRange = html[match].range(of: #"content="([^"]*)""#, options: .regularExpression) {
            let raw = String(html[contentRange])
            let value = raw.replacingOccurrences(of: #"content=""#, with: "")
                .replacingOccurrences(of: "\"", with: "")
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - Subprocess

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private static func runProcess(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": NSHomeDirectory(),
            ]

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 15)
            timer.setEventHandler { process.terminate() }
            timer.resume()

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

    // MARK: - Constants

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}
