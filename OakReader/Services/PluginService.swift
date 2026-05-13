import Foundation
import OakAgent

// MARK: - Plugin Service

/// App-side plugin registry that mirrors the CLI's `PluginRegistry` but is `@Observable` for SwiftUI.
/// Loads bundled plugins + filesystem plugins from `~/.oak/plugins/`.
@Observable
final class PluginService {
    static let shared = PluginService()

    private(set) var plugins: [PluginManifest] = []
    private(set) var toolStatuses: [String: ToolStatus] = [:]

    struct ToolStatus {
        let tool: PluginManifest.ToolDeclaration
        let pluginName: String
        let path: String?
        let version: String?
    }

    /// Directory where user-installed plugins live: `~/.oak/plugins/`.
    static let userPluginsDirectory: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".oak/plugins")
    }()

    private static let _bundledPlugins = bundledPlugins()

    private init() {
        // Load plugin list synchronously (fast — no subprocess calls).
        var all = Self._bundledPlugins
        all.append(contentsOf: loadWorkspacePlugins())
        plugins = all
        // Resolve tool paths and versions in the background.
        rebuildToolStatusesAsync()
    }

    // MARK: - Reload

    /// Rescan bundled + `~/.oak/plugins/` and rebuild tool statuses.
    func reload() {
        var all = Self._bundledPlugins
        all.append(contentsOf: loadWorkspacePlugins())
        plugins = all
        rebuildToolStatusesAsync()
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

    // MARK: - Enable/Disable

    func isEnabled(_ pluginName: String) -> Bool {
        Preferences.shared.isExternalPluginEnabled(pluginName)
    }

    func setEnabled(_ pluginName: String, _ enabled: Bool) {
        Preferences.shared.setExternalPlugin(pluginName, enabled: enabled)
    }

    // MARK: - Skill Directories

    /// Returns resolved paths to each enabled plugin's `skills/` directories.
    func pluginSkillDirectories() -> [URL] {
        var dirs: [URL] = []

        for plugin in plugins {
            guard isEnabled(plugin.name) else { continue }

            for skillPath in plugin.skills {
                // Resolve relative skill paths against the plugin's directory
                let resolved: URL
                if skillPath.hasPrefix("./") || !skillPath.hasPrefix("/") {
                    // For bundled plugins, skills are relative — skip (no filesystem root)
                    // For workspace plugins, resolve relative to plugin dir
                    if let pluginDir = workspacePluginDirectory(for: plugin.name) {
                        let relative = skillPath.hasPrefix("./") ? String(skillPath.dropFirst(2)) : skillPath
                        resolved = pluginDir.appendingPathComponent(relative)
                    } else {
                        continue
                    }
                } else {
                    resolved = URL(fileURLWithPath: skillPath)
                }

                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
                    dirs.append(resolved)
                }
            }
        }

        return dirs
    }

    // MARK: - Queries

    /// Find which plugin owns a given tool.
    func plugin(forTool name: String) -> PluginManifest? {
        plugins.first { $0.tools.contains { $0.name == name } }
    }

    /// Find tool declaration by name.
    func toolDeclaration(named name: String) -> PluginManifest.ToolDeclaration? {
        for plugin in plugins {
            if let tool = plugin.tools.first(where: { $0.name == name }) {
                return tool
            }
        }
        return nil
    }

    /// Check tools for a specific plugin.
    func checkTools(for plugin: PluginManifest) -> [ToolStatus] {
        plugin.tools.map { tool in
            let path = resolve(tool: tool)
            let ver = path.flatMap { version(tool: tool, at: $0) }
            return ToolStatus(tool: tool, pluginName: plugin.name, path: path, version: ver)
        }
    }

    /// Whether a plugin is bundled (vs. workspace-installed).
    func isBundled(_ pluginName: String) -> Bool {
        Self._bundledPlugins.contains { $0.name == pluginName }
    }

    // MARK: - Filesystem Loading

    func loadWorkspacePlugins() -> [PluginManifest] {
        let fm = FileManager.default
        let dir = Self.userPluginsDirectory

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

        var result: [PluginManifest] = []
        let decoder = JSONDecoder()

        for entry in entries {
            var entryIsDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &entryIsDir)
            guard entryIsDir.boolValue else { continue }

            let manifestURL = entry.appendingPathComponent("plugin.json")
            guard let data = fm.contents(atPath: manifestURL.path) else { continue }

            do {
                let manifest = try decoder.decode(PluginManifest.self, from: data)
                result.append(manifest)
            } catch {
                // Skip malformed manifests
            }
        }

        return result
    }

    // MARK: - Private

    /// Return the filesystem directory for a workspace plugin.
    private func workspacePluginDirectory(for name: String) -> URL? {
        let dir = Self.userPluginsDirectory.appendingPathComponent(name)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
            return dir
        }
        return nil
    }

    private func rebuildToolStatusesAsync() {
        let currentPlugins = plugins
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var statuses: [String: ToolStatus] = [:]
            for plugin in currentPlugins {
                for tool in plugin.tools {
                    let path = resolve(tool: tool)
                    let ver = path.flatMap { version(tool: tool, at: $0) }
                    statuses[tool.name] = ToolStatus(tool: tool, pluginName: plugin.name, path: path, version: ver)
                }
            }
            DispatchQueue.main.async {
                self.toolStatuses = statuses
            }
        }
    }

    private func version(tool decl: PluginManifest.ToolDeclaration, at path: String) -> String? {
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
            return output?.components(separatedBy: .newlines).first
        } catch {
            return nil
        }
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
}

// MARK: - Bundled Plugin Definitions

extension PluginService {
    private static let appSupportBin = "~/Library/Application Support/OakReader/bin"

    static func bundledPlugins() -> [PluginManifest] {
        [webImport, youtube, transcription, typesetting, ai]
    }

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
