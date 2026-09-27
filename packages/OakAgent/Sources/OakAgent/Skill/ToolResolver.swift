import Foundation

/// What is left of tool resolution on this side: probing a binary's version and
/// installing one.
///
/// Finding a tool moved to the core with the skill manifests that declare it —
/// see `SkillStore.binPath(named:)`. These two stayed because they are actions
/// on this machine rather than readings of a file.
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
    /// Install a tool a skill needs.
    ///
    /// Takes the coordinates rather than a manifest type: the manifest is read
    /// by the core now, and this side is handed what it needs to run — which
    /// is what installing is, and the one part of this that has to happen here.
    public static func install(name: String, install method: [String: String]) throws {
        let brew = method["brew"]
        let url = method["url"]
        guard brew != nil || url != nil else { throw InstallError.noInstallMethod(name) }

        // brew first, falling back to a download when it is absent or fails.
        if let brew, brewAvailable() {
            do {
                try installViaBrew(formula: brew)
                return
            } catch {
                if url == nil { throw error }
            }
        }

        if let url {
            try installViaDownload(url: url, toolName: name)
        } else if let brew {
            // brew was the only method and was not available.
            try installViaBrew(formula: brew)
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
