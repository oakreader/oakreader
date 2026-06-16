import AppKit
import Foundation

// MARK: - Progress & Result Types

enum BackupPhase: String {
    case preparing = "Preparing backup..."
    case checkpointing = "Checkpointing database..."
    case copying = "Copying files..."
    case compressing = "Compressing archive..."
    case done = "Done"
}

enum RestorePhase: String {
    case preparing = "Preparing restore..."
    case extracting = "Extracting archive..."
    case validating = "Validating backup..."
    case replacing = "Replacing library..."
    case done = "Done"
}

struct BackupProgress {
    var phase: BackupPhase = .preparing
    var current: Int = 0
    var total: Int = 0
    var currentFileName: String = ""
}

struct RestoreProgress {
    var phase: RestorePhase = .preparing
    var current: Int = 0
    var total: Int = 0
    var currentFileName: String = ""
}

struct BackupResult {
    var fileCount: Int = 0
    var totalSize: Int64 = 0
    var archiveSize: Int64 = 0
    var outputURL: URL?
    var errors: [String] = []
}

struct RestoreResult {
    var success: Bool = false
    var errors: [String] = []
}

struct BackupManifest: Codable {
    let format: String
    let appVersion: String
    let exportDate: String
    let schemaVersion: String
    let itemCount: Int
}

// MARK: - Backup Service

final class BackupService {
    private let fm = FileManager.default

    /// Directories to include in backup (relative to ~/OakReader/).
    private let includedDirectories = ["storage", "chats", "agent"]

    /// Files/directories to exclude from backup.
    private let excludedNames: Set<String> = [
        "search.sqlite", "logs"
    ]

    // MARK: - Export

    func export(
        to destinationURL: URL,
        progress: @escaping (BackupProgress) -> Void
    ) async -> BackupResult {
        var result = BackupResult()
        var prog = BackupProgress()

        let dataDir = CatalogDatabase.dataDirectory
        let tempDir = fm.temporaryDirectory.appendingPathComponent("oakreader-backup-\(UUID().uuidString)")

        defer {
            try? fm.removeItem(at: tempDir)
        }

        // Phase 1: Prepare temp directory
        prog.phase = .preparing
        progress(prog)

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            result.errors.append("Failed to create temp directory: \(error.localizedDescription)")
            return result
        }

        // Check available disk space
        let estimatedSize = estimateBackupSize(dataDir: dataDir)
        if let availableSpace = availableDiskSpace(), availableSpace < estimatedSize * 2 {
            let needed = ByteCountFormatter.string(fromByteCount: estimatedSize * 2, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: availableSpace, countStyle: .file)
            result.errors.append("Insufficient disk space. Need approximately \(needed) but only \(available) available.")
            return result
        }

        // Phase 2: Checkpoint WAL
        prog.phase = .checkpointing
        progress(prog)

        let checkpointSuccess = await checkpointDatabase(dataDir: dataDir)
        if !checkpointSuccess {
            result.errors.append("WAL checkpoint failed (non-fatal, backup may include stale data)")
        }

        // Phase 3: Copy files
        prog.phase = .copying
        progress(prog)

        // Copy library.sqlite
        let dbSource = dataDir.appendingPathComponent("library.sqlite")
        let dbDest = tempDir.appendingPathComponent("library.sqlite")
        if fm.fileExists(atPath: dbSource.path) {
            do {
                try fm.copyItem(at: dbSource, to: dbDest)
                result.fileCount += 1
                if let size = fileSize(at: dbSource) {
                    result.totalSize += size
                }
            } catch {
                result.errors.append("Failed to copy library.sqlite: \(error.localizedDescription)")
                return result
            }
        }

        // Enumerate and copy included directories
        let allFiles = enumerateFilesToCopy(dataDir: dataDir)
        prog.total = allFiles.count
        prog.current = 0

        for (relativePath, sourceURL) in allFiles {
            prog.current += 1
            prog.currentFileName = sourceURL.lastPathComponent
            progress(prog)

            let destURL = tempDir.appendingPathComponent(relativePath)
            let destParent = destURL.deletingLastPathComponent()

            do {
                if !fm.fileExists(atPath: destParent.path) {
                    try fm.createDirectory(at: destParent, withIntermediateDirectories: true)
                }
                try fm.copyItem(at: sourceURL, to: destURL)
                result.fileCount += 1
                if let size = fileSize(at: sourceURL) {
                    result.totalSize += size
                }
            } catch {
                result.errors.append("Failed to copy \(relativePath): \(error.localizedDescription)")
            }
        }

        // Write manifest
        let manifest = BackupManifest(
            format: "oakreader-backup-v1",
            appVersion: appVersion,
            exportDate: ISO8601DateFormatter().string(from: Date()),
            schemaVersion: "v9",
            itemCount: countItems(dataDir: dataDir)
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: tempDir.appendingPathComponent("manifest.json"))
            result.fileCount += 1
        } catch {
            result.errors.append("Failed to write manifest: \(error.localizedDescription)")
        }

        // Phase 4: Compress
        prog.phase = .compressing
        prog.current = 0
        prog.total = 0
        prog.currentFileName = ""
        progress(prog)

        let compressResult = await compressDirectory(source: tempDir, destination: destinationURL)
        if let compressError = compressResult {
            result.errors.append("Compression failed: \(compressError)")
            return result
        }

        if let archiveSize = fileSize(at: destinationURL) {
            result.archiveSize = archiveSize
        }
        result.outputURL = destinationURL

        prog.phase = .done
        progress(prog)

        Log.info(Log.store, "Backup export complete: \(result.fileCount) files, " +
            "\(ByteCountFormatter.string(fromByteCount: result.totalSize, countStyle: .file)) total, " +
            "\(ByteCountFormatter.string(fromByteCount: result.archiveSize, countStyle: .file)) archive, " +
            "\(result.errors.count) errors")

        return result
    }

    // MARK: - Restore

    func restore(
        from archiveURL: URL,
        progress: @escaping (RestoreProgress) -> Void
    ) async -> RestoreResult {
        var result = RestoreResult()
        var prog = RestoreProgress()

        let dataDir = CatalogDatabase.dataDirectory
        let tempDir = fm.temporaryDirectory.appendingPathComponent("oakreader-restore-\(UUID().uuidString)")

        defer {
            try? fm.removeItem(at: tempDir)
        }

        // Phase 1: Prepare
        prog.phase = .preparing
        progress(prog)

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            result.errors.append("Failed to create temp directory: \(error.localizedDescription)")
            return result
        }

        // Phase 2: Extract
        prog.phase = .extracting
        progress(prog)

        let extractError = await extractArchive(source: archiveURL, destination: tempDir)
        if let error = extractError {
            result.errors.append("Extraction failed: \(error)")
            return result
        }

        // Find the extracted content (ditto may create a subfolder with --keepParent)
        let extractedDir = findExtractedRoot(in: tempDir)

        // Phase 3: Validate
        prog.phase = .validating
        progress(prog)

        let manifestURL = extractedDir.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            result.errors.append("Invalid backup: manifest.json not found. This may not be a valid OakReader backup.")
            return result
        }

        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(BackupManifest.self, from: data)

            guard manifest.format == "oakreader-backup-v1" else {
                result.errors.append("Unknown backup format: \(manifest.format)")
                return result
            }

            // Check schema version compatibility
            let currentVersion = 9
            if let backupVersion = extractVersion(manifest.schemaVersion),
               backupVersion > currentVersion {
                result.errors.append("This backup was created with a newer version of OakReader (schema \(manifest.schemaVersion)). Please update OakReader before restoring.")
                return result
            }
        } catch {
            result.errors.append("Failed to read manifest: \(error.localizedDescription)")
            return result
        }

        // Verify library.sqlite exists
        guard fm.fileExists(atPath: extractedDir.appendingPathComponent("library.sqlite").path) else {
            result.errors.append("Invalid backup: library.sqlite not found.")
            return result
        }

        // Phase 4: Replace
        prog.phase = .replacing
        progress(prog)

        // Safety: rename current data directory
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backupName = "OakReader-pre-restore-\(timestamp)"
        let safetyBackup = fm.homeDirectoryForCurrentUser.appendingPathComponent(backupName)

        do {
            if fm.fileExists(atPath: dataDir.path) {
                try fm.moveItem(at: dataDir, to: safetyBackup)
            }
        } catch {
            result.errors.append("Failed to move current data directory: \(error.localizedDescription)")
            return result
        }

        // Copy extracted contents to ~/OakReader/
        do {
            try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)

            let contents = try fm.contentsOfDirectory(
                at: extractedDir,
                includingPropertiesForKeys: nil
            )

            prog.total = contents.count
            prog.current = 0

            for item in contents {
                prog.current += 1
                prog.currentFileName = item.lastPathComponent
                progress(prog)

                let destURL = dataDir.appendingPathComponent(item.lastPathComponent)
                try fm.copyItem(at: item, to: destURL)
            }
        } catch {
            // Attempt to restore the safety backup
            try? fm.removeItem(at: dataDir)
            try? fm.moveItem(at: safetyBackup, to: dataDir)
            result.errors.append("Restore failed, original data preserved: \(error.localizedDescription)")
            return result
        }

        // Merge installed skills from the previous data that are not in the backup.
        // This prevents personal (non-bundled) skills from being lost on restore.
        let oldSkillsDir = safetyBackup.appendingPathComponent("skills")
        let newSkillsDir = dataDir.appendingPathComponent("skills")
        if fm.fileExists(atPath: oldSkillsDir.path) {
            try? fm.createDirectory(at: newSkillsDir, withIntermediateDirectories: true)
            if let oldEntries = try? fm.contentsOfDirectory(
                at: oldSkillsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for entry in oldEntries {
                    let dest = newSkillsDir.appendingPathComponent(entry.lastPathComponent)
                    if !fm.fileExists(atPath: dest.path) {
                        try? fm.copyItem(at: entry, to: dest)
                    }
                }
            }
        }

        result.success = true
        prog.phase = .done
        progress(prog)

        Log.info(Log.store, "Backup restore complete. Previous data saved at: \(safetyBackup.path)")

        return result
    }

    // MARK: - Relaunch

    static func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        // Use a shell script that waits for this process to exit, then reopens the app.
        // This avoids two simultaneous instances (and two dock icons).
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done
        open "\(bundlePath)"
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        do {
            try task.run()
        } catch {
            // Relaunch is best-effort; if it fails the user must reopen manually,
            // so surface it rather than swallowing the error silently.
            NSLog("BackupService.relaunchApp: failed to spawn relaunch helper: \(error)")
        }

        // Hard exit — terminate(nil) can be blocked by open sheets.
        // After a restore the data directory has already been replaced,
        // so there is nothing to save.
        exit(0)
    }

    // MARK: - Private Helpers

    private func enumerateFilesToCopy(dataDir: URL) -> [(String, URL)] {
        var files: [(String, URL)] = []

        for dirName in includedDirectories {
            let dirURL = dataDir.appendingPathComponent(dirName)
            guard fm.fileExists(atPath: dirURL.path) else { continue }

            guard let enumerator = fm.enumerator(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            while let fileURL = enumerator.nextObject() as? URL {
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else { continue }

                let relativePath = dirName + "/" + fileURL.path.dropFirst(dirURL.path.count + 1)
                files.append((String(relativePath), fileURL))
            }
        }

        return files
    }

    private func checkpointDatabase(dataDir: URL) async -> Bool {
        let dbPath = dataDir.appendingPathComponent("library.sqlite").path
        guard fm.fileExists(atPath: dbPath) else { return true }

        for attempt in 1...3 {
            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                return false
            }
            defer { sqlite3_close(db) }

            var pnLog: Int32 = 0
            var pnCkpt: Int32 = 0
            let rc = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, &pnLog, &pnCkpt)
            if rc == SQLITE_OK {
                return true
            }

            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        return false
    }

    private func compressDirectory(source: URL, destination: URL) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--norsrc", source.path, destination.path]

            let errPipe = Pipe()
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error (exit \(process.terminationStatus))"
                    continuation.resume(returning: errStr)
                }
            } catch {
                continuation.resume(returning: error.localizedDescription)
            }
        }
    }

    private func extractArchive(source: URL, destination: URL) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", source.path, destination.path]

            let errPipe = Pipe()
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error (exit \(process.terminationStatus))"
                    continuation.resume(returning: errStr)
                }
            } catch {
                continuation.resume(returning: error.localizedDescription)
            }
        }
    }

    private func findExtractedRoot(in dir: URL) -> URL {
        // ditto with --keepParent creates a subfolder named after the source dir
        if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
           contents.count == 1,
           contents[0].hasDirectoryPath {
            // Check if this single subfolder contains manifest.json
            let candidate = contents[0]
            if fm.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
                return candidate
            }
        }
        return dir
    }

    private func estimateBackupSize(dataDir: URL) -> Int64 {
        var total: Int64 = 0

        // library.sqlite
        if let size = fileSize(at: dataDir.appendingPathComponent("library.sqlite")) {
            total += size
        }

        for dirName in includedDirectories {
            let dirURL = dataDir.appendingPathComponent(dirName)
            total += directorySize(at: dirURL)
        }

        return total
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    private func availableDiskSpace() -> Int64? {
        let homeDir = fm.homeDirectoryForCurrentUser
        guard let values = try? homeDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return capacity
    }

    private func countItems(dataDir: URL) -> Int {
        let dbPath = dataDir.appendingPathComponent("library.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM items", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int(stmt, 0))
        }
        return 0
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private func extractVersion(_ versionString: String) -> Int? {
        let digits = versionString.drop(while: { !$0.isNumber })
        return Int(digits)
    }
}

// SQLite3 import for checkpoint
import SQLite3
