import Foundation

// MARK: - Plugin Registry

final class PluginRegistry {
    static let shared = PluginRegistry()

    let plugins: [PluginManifest]

    private init() {
        var all = Self.bundledPlugins()
        all.append(contentsOf: Self.loadWorkspacePlugins())
        self.plugins = all
    }

    // MARK: - Workspace Plugin Loading

    /// Directory where user-installed plugins live: `~/.oak/plugins/`.
    static let userPluginsDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".oak/plugins")
    }()

    /// Scan `~/.oak/plugins/*/plugin.json` and decode each manifest.
    static func loadWorkspacePlugins() -> [PluginManifest] {
        let fm = FileManager.default
        let dir = userPluginsDirectory

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var plugins: [PluginManifest] = []
        let decoder = JSONDecoder()

        for entry in entries {
            var entryIsDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &entryIsDir)
            guard entryIsDir.boolValue else { continue }

            let manifestURL = entry.appendingPathComponent("plugin.json")
            guard let data = fm.contents(atPath: manifestURL.path) else { continue }

            do {
                let manifest = try decoder.decode(PluginManifest.self, from: data)
                plugins.append(manifest)
            } catch {
                // Skip malformed manifests silently
            }
        }

        return plugins
    }

    /// Whether a plugin is a bundled plugin (vs. workspace-installed).
    func isBundled(_ pluginName: String) -> Bool {
        Self.bundledPlugins().contains { $0.name == pluginName }
    }

    // MARK: - Aggregated Declarations

    /// All tool declarations across all plugins, deduplicated by name.
    var allTools: [PluginManifest.ToolDeclaration] {
        var seen = Set<String>()
        var result: [PluginManifest.ToolDeclaration] = []
        for plugin in plugins {
            for tool in plugin.tools {
                if seen.insert(tool.name).inserted {
                    result.append(tool)
                }
            }
        }
        return result
    }

    /// All credential declarations across all plugins, deduplicated by providerId.
    var allCredentials: [PluginManifest.CredentialDeclaration] {
        var seen = Set<String>()
        var result: [PluginManifest.CredentialDeclaration] = []
        for plugin in plugins {
            for cred in plugin.credentials {
                if seen.insert(cred.providerId).inserted {
                    result.append(cred)
                }
            }
        }
        return result
    }

    /// Find which plugin owns a given tool.
    func plugin(forTool name: String) -> PluginManifest? {
        plugins.first { $0.tools.contains { $0.name == name } }
    }

    /// Find tool declaration by name.
    func toolDeclaration(named name: String) -> PluginManifest.ToolDeclaration? {
        allTools.first { $0.name == name }
    }

    // MARK: - Tool Resolution

    /// Resolve a tool binary path: check declared searchPaths first, then `which` fallback.
    func resolve(tool name: String) -> String? {
        guard let decl = toolDeclaration(named: name) else {
            return whichFallback(name)
        }
        return resolve(tool: decl)
    }

    func resolve(tool decl: PluginManifest.ToolDeclaration) -> String? {
        let fm = FileManager.default
        for searchPath in decl.searchPaths {
            let expanded = (searchPath as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }
        return whichFallback(decl.name)
    }

    private func whichFallback(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (path?.isEmpty == false) ? path : nil
        } catch {
            return nil
        }
    }

    // MARK: - Version Detection

    func version(tool decl: PluginManifest.ToolDeclaration, at path: String) -> String? {
        guard !decl.versionArgs.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = decl.versionArgs
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Take first line only (many tools print multi-line version info)
            return output?.components(separatedBy: .newlines).first
        } catch {
            return nil
        }
    }

    // MARK: - Status Check

    struct ToolStatus {
        let tool: PluginManifest.ToolDeclaration
        let pluginName: String
        let path: String?
        let version: String?
    }

    func checkAll() -> [ToolStatus] {
        var results: [ToolStatus] = []
        for plugin in plugins {
            for tool in plugin.tools {
                let path = resolve(tool: tool)
                let ver = path.flatMap { version(tool: tool, at: $0) }
                results.append(ToolStatus(tool: tool, pluginName: plugin.name, path: path, version: ver))
            }
        }
        return results
    }

    func checkTools(for plugin: PluginManifest) -> [ToolStatus] {
        plugin.tools.map { tool in
            let path = resolve(tool: tool)
            let ver = path.flatMap { version(tool: tool, at: $0) }
            return ToolStatus(tool: tool, pluginName: plugin.name, path: path, version: ver)
        }
    }

    // MARK: - Install

    enum InstallError: LocalizedError {
        case unknownTool(String)
        case noInstallMethod(String)
        case brewFailed(String, Int32)
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .unknownTool(let name):
                return "Unknown tool '\(name)'. Run 'oak tools' to see available tools."
            case .noInstallMethod(let name):
                return "No install method defined for '\(name)'."
            case .brewFailed(let formula, let code):
                return "brew install \(formula) failed with exit code \(code)."
            case .downloadFailed(let msg):
                return "Download failed: \(msg)"
            }
        }
    }

    func install(tool name: String) throws {
        guard let decl = toolDeclaration(named: name) else {
            throw InstallError.unknownTool(name)
        }

        if let brew = decl.install.brew {
            try installViaBrew(formula: brew)
        } else if let download = decl.install.download {
            try installViaDownload(source: download, toolName: name)
        } else {
            throw InstallError.noInstallMethod(name)
        }
    }

    private func installViaBrew(formula: String) throws {
        print("Running: brew install \(formula)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["brew", "install", formula]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.brewFailed(formula, process.terminationStatus)
        }
    }

    private func installViaDownload(source: PluginManifest.ToolDeclaration.InstallMethod.DownloadSource, toolName: String) throws {
        let destDir = (source.toDir as NSString).expandingTildeInPath
        let fm = FileManager.default

        // Create destination directory if needed
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        guard let url = URL(string: source.url) else {
            throw InstallError.downloadFailed("Invalid URL: \(source.url)")
        }

        print("Downloading \(toolName) from \(source.url)...")

        // Synchronous download via URLSession
        let semaphore = DispatchSemaphore(value: 0)
        var downloadError: Error?
        var tempFileURL: URL?

        let task = URLSession.shared.downloadTask(with: url) { localURL, _, error in
            if let error {
                downloadError = error
            } else {
                tempFileURL = localURL
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let error = downloadError {
            throw InstallError.downloadFailed(error.localizedDescription)
        }

        guard let tempFile = tempFileURL else {
            throw InstallError.downloadFailed("No data received.")
        }

        let destPath = (destDir as NSString).appendingPathComponent(toolName)
        let destURL = URL(fileURLWithPath: destPath)

        // Remove existing file if present
        try? fm.removeItem(at: destURL)
        try fm.moveItem(at: tempFile, to: destURL)

        // Make executable
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath)

        print("Installed \(toolName) to \(destPath)")
    }
}

// MARK: - Bundled Plugin Definitions

extension PluginRegistry {
    private static let appSupportBin = "~/Library/Application Support/OakReader/bin"

    static func bundledPlugins() -> [PluginManifest] {
        [webImport, youtube, transcription, typesetting, ai]
    }

    // MARK: web-import

    private static let webImport = PluginManifest(
        name: "web-import",
        version: "1.0.0",
        description: "Import web pages as offline snapshots",
        tools: [
            .init(
                name: "monolith",
                description: "Save web pages as single HTML files",
                required: true,
                searchPaths: [
                    "\(appSupportBin)/monolith",
                    "/opt/homebrew/bin/monolith",
                    "/usr/local/bin/monolith",
                ],
                install: .init(brew: "monolith", download: nil),
                versionArgs: ["--version"]
            ),
            .init(
                name: "pandoc",
                description: "Convert HTML to Markdown for AI context",
                required: false,
                searchPaths: [
                    "/opt/homebrew/bin/pandoc",
                    "/usr/local/bin/pandoc",
                ],
                install: .init(brew: "pandoc", download: nil),
                versionArgs: ["--version"]
            ),
        ],
        skills: ["./skills/"],
        credentials: [],
        commands: ["import"]
    )

    // MARK: youtube

    private static let youtube = PluginManifest(
        name: "youtube",
        version: "1.0.0",
        description: "Download and manage YouTube videos",
        tools: [
            .init(
                name: "yt-dlp",
                description: "Download YouTube videos and metadata",
                required: false,
                searchPaths: [
                    "\(appSupportBin)/yt-dlp",
                    "/opt/homebrew/bin/yt-dlp",
                    "/usr/local/bin/yt-dlp",
                ],
                install: .init(
                    brew: nil,
                    download: .init(
                        url: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos",
                        toDir: appSupportBin
                    )
                ),
                versionArgs: ["--version"]
            ),
        ],
        skills: ["./skills/"],
        credentials: [],
        commands: []
    )

    // MARK: transcription

    private static let transcription = PluginManifest(
        name: "transcription",
        version: "1.0.0",
        description: "Transcribe audio and video files",
        tools: [
            .init(
                name: "whisper-cpp",
                description: "Fast local speech-to-text transcription",
                required: false,
                searchPaths: [
                    "\(appSupportBin)/whisper-cpp",
                    "/opt/homebrew/bin/whisper-cpp",
                    "/usr/local/bin/whisper-cpp",
                ],
                install: .init(brew: "whisper-cpp", download: nil),
                versionArgs: ["--version"]
            ),
        ],
        skills: ["./skills/"],
        credentials: [],
        commands: ["transcribe"]
    )

    // MARK: typesetting

    private static let typesetting = PluginManifest(
        name: "typesetting",
        version: "1.0.0",
        description: "Export documents with professional typesetting",
        tools: [
            .init(
                name: "typst",
                description: "Modern typesetting system for documents",
                required: false,
                searchPaths: [
                    "\(appSupportBin)/typst",
                    "/opt/homebrew/bin/typst",
                    "/usr/local/bin/typst",
                ],
                install: .init(brew: "typst", download: nil),
                versionArgs: ["--version"]
            ),
        ],
        skills: ["./skills/"],
        credentials: [],
        commands: ["export"]
    )

    // MARK: ai

    private static let ai = PluginManifest(
        name: "ai",
        version: "1.0.0",
        description: "AI chat and document analysis",
        tools: [],
        skills: [],
        credentials: [
            .init(providerId: "anthropic", displayName: "Anthropic (Claude)", envVar: "ANTHROPIC_API_KEY"),
            .init(providerId: "openai", displayName: "OpenAI", envVar: "OPENAI_API_KEY"),
            .init(providerId: "google", displayName: "Google (Gemini)", envVar: "GEMINI_API_KEY"),
            .init(providerId: "openrouter", displayName: "OpenRouter", envVar: "OPENROUTER_API_KEY"),
            .init(providerId: "deepseek", displayName: "DeepSeek", envVar: "DEEPSEEK_API_KEY"),
        ],
        commands: ["chat"]
    )
}
