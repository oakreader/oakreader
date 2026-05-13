import Foundation

/// Standalone tool binary resolution, replacing the plugin-based resolver.
///
/// Resolves tool binaries by checking explicit search paths from `skill.json` first,
/// then falling back to `which` via `/usr/bin/env`.
public enum ToolResolver {

    /// Resolve a tool binary by name.
    ///
    /// If `searchPaths` is provided, checks each path for an executable.
    /// Always falls back to `which` if no search path matches.
    public static func resolve(name: String, searchPaths: [String]? = nil) -> String? {
        let fm = FileManager.default

        if let paths = searchPaths {
            for searchPath in paths {
                let expanded = (searchPath as NSString).expandingTildeInPath
                if fm.isExecutableFile(atPath: expanded) {
                    return expanded
                }
            }
        }

        return whichFallback(name)
    }

    /// Resolve a tool binary from a `BinRequirement` (reads searchPaths from skill.json).
    public static func resolve(bin: BinRequirement) -> String? {
        resolve(name: bin.name, searchPaths: bin.searchPaths)
    }

    /// Look up a `BinRequirement` by name from installed skills, then resolve it.
    ///
    /// Scans `~/OakReader/agent/skills/` for a skill whose `skill.json` declares
    /// a bin with the given name, and resolves using its searchPaths.
    public static func resolveFromInstalledSkills(name: String) -> String? {
        let installedDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("OakReader/agent/skills")
        let skills = SkillLoader.loadSkills(from: [installedDir]).skills

        for skill in skills {
            guard let bins = skill.requirements?.bins else { continue }
            if let bin = bins.first(where: { $0.name == name }) {
                if let path = resolve(bin: bin) {
                    return path
                }
            }
        }

        // Final fallback: which
        return whichFallback(name)
    }

    /// Run a binary with version arguments and return the first line of output.
    public static func version(at path: String, versionArgs: [String]) -> String? {
        guard !versionArgs.isEmpty else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = versionArgs
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

    // MARK: - Install

    public enum InstallError: LocalizedError {
        case noInstallMethod(String)
        case brewFailed(String, Int32)
        case downloadFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noInstallMethod(let name):
                return "No install method defined for '\(name)'."
            case .brewFailed(let formula, let code):
                return "brew install \(formula) failed with exit code \(code)."
            case .downloadFailed(let msg):
                return "Download failed: \(msg)"
            }
        }
    }

    /// Install a binary using the method declared in `skill.json`.
    public static func install(bin: BinRequirement) throws {
        guard let method = bin.install else {
            throw InstallError.noInstallMethod(bin.name)
        }

        // Try brew first; if brew is not installed or fails, fall back to URL download
        if let brew = method.brew {
            if brewAvailable() {
                do {
                    try installViaBrew(formula: brew)
                    return
                } catch {
                    // brew failed — fall through to URL if available
                }
            }
        }

        if let url = method.url {
            try installViaDownload(url: url, toolName: bin.name)
        } else if method.brew != nil {
            // brew was the only method and it failed or wasn't available
            try installViaBrew(formula: method.brew!)
        } else {
            throw InstallError.noInstallMethod(bin.name)
        }
    }

    private static func installViaBrew(formula: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["brew", "install", formula]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.brewFailed(formula, process.terminationStatus)
        }
    }

    private static func installViaDownload(url urlString: String, toolName: String) throws {
        let destDir = ("~/Library/Application Support/OakReader/bin" as NSString).expandingTildeInPath
        let fm = FileManager.default
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        guard let url = URL(string: urlString) else {
            throw InstallError.downloadFailed("Invalid URL: \(urlString)")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var downloadError: Error?
        var tempFileURL: URL?

        let task = URLSession.shared.downloadTask(with: url) { localURL, _, error in
            if let error { downloadError = error }
            else { tempFileURL = localURL }
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

        let sourceURL: URL
        let lowerURL = urlString.lowercased()
        if lowerURL.hasSuffix(".tar.gz") || lowerURL.hasSuffix(".tgz") || lowerURL.hasSuffix(".zip") {
            let extractionDir = fm.temporaryDirectory
                .appendingPathComponent("OakReaderToolInstall-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: extractionDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: extractionDir) }

            if lowerURL.hasSuffix(".zip") {
                try runArchiveTool("/usr/bin/unzip", arguments: ["-q", tempFile.path, "-d", extractionDir.path])
            } else {
                try runArchiveTool("/usr/bin/tar", arguments: ["-xzf", tempFile.path, "-C", extractionDir.path])
            }

            guard let binary = findExecutable(named: toolName, in: extractionDir) else {
                throw InstallError.downloadFailed("Could not find executable '\(toolName)' in downloaded archive.")
            }
            sourceURL = binary
        } else {
            sourceURL = tempFile
        }

        let destPath = (destDir as NSString).appendingPathComponent(toolName)
        let destURL = URL(fileURLWithPath: destPath)
        try? fm.removeItem(at: destURL)
        try fm.moveItem(at: sourceURL, to: destURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath)
    }

    private static func runArchiveTool(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw InstallError.downloadFailed("Archive extraction failed with exit code \(process.terminationStatus).")
        }
    }

    private static func findExecutable(named name: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard url.lastPathComponent == name else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true {
                return url
            }
        }
        return nil
    }

    // MARK: - Private

    private static func brewAvailable() -> Bool {
        whichFallback("brew") != nil
    }

    private static func whichFallback(_ name: String) -> String? {
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
