import Foundation
import os

// MARK: - Log Facade

/// Central logging facade that writes to both `os.Logger` (for Console.app / Xcode) and a
/// rotating log file at `~/OakReader/logs/oakreader.log` (for user-reportable diagnostics).
enum Log {
    // MARK: Categories

    static let store     = Logger(subsystem: subsystem, category: "store")
    static let importer   = Logger(subsystem: subsystem, category: "import")
    static let open      = Logger(subsystem: subsystem, category: "open")
    static let server    = Logger(subsystem: subsystem, category: "server")
    static let migration = Logger(subsystem: subsystem, category: "migration")
    static let cover     = Logger(subsystem: subsystem, category: "cover")
    static let ui        = Logger(subsystem: subsystem, category: "ui")
    static let chapters  = Logger(subsystem: subsystem, category: "chapters")
    static let zotero     = Logger(subsystem: subsystem, category: "zotero")
    static let voice      = Logger(subsystem: subsystem, category: "voice")
    static let characters = Logger(subsystem: subsystem, category: "characters")
    static let stt        = Logger(subsystem: subsystem, category: "stt")
    static let tts        = Logger(subsystem: subsystem, category: "tts")
    static let semantic   = Logger(subsystem: subsystem, category: "semantic")
    static let audio      = Logger(subsystem: subsystem, category: "audio")
    static let search     = Logger(subsystem: subsystem, category: "search")
    static let meeting    = Logger(subsystem: subsystem, category: "meeting")
    static let crash      = Logger(subsystem: subsystem, category: "crash")

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.oakreader.OakReader"

    // MARK: Convenience — dual output

    /// Debug-level: os.Logger only, NOT written to file.
    static func debug(_ logger: Logger, _ message: String) {
        logger.debug("\(message)")
    }

    /// Info-level: os.Logger + file.
    static func info(_ logger: Logger, _ message: String) {
        logger.info("\(message)")
        LogFileWriter.shared.write(level: "info", category: logger.category, message: message)
    }

    /// Notice-level: os.Logger + file.
    static func notice(_ logger: Logger, _ message: String) {
        logger.notice("\(message)")
        LogFileWriter.shared.write(level: "notice", category: logger.category, message: message)
    }

    /// Warning-level: os.Logger + file.
    static func warning(_ logger: Logger, _ message: String) {
        logger.warning("\(message)")
        LogFileWriter.shared.write(level: "warning", category: logger.category, message: message)
    }

    /// Error-level: os.Logger + file.
    static func error(_ logger: Logger, _ message: String) {
        logger.error("\(message)")
        LogFileWriter.shared.write(level: "error", category: logger.category, message: message)
    }

    /// Fault-level: os.Logger + file.
    static func fault(_ logger: Logger, _ message: String) {
        logger.fault("\(message)")
        LogFileWriter.shared.write(level: "fault", category: logger.category, message: message)
    }

    /// The current log file URL (for export).
    static var logFileURL: URL { LogFileWriter.shared.logFileURL }
}

// MARK: - Logger+category

private extension Logger {
    /// Extract the category string from an `os.Logger`.
    /// `os.Logger` doesn't expose `category` publicly, so we store the mapping ourselves.
    var category: String {
        // Match against known loggers
        switch self {
        case Log.store:     return "store"
        case Log.importer:   return "import"
        case Log.open:      return "open"
        case Log.server:    return "server"
        case Log.migration: return "migration"
        case Log.cover:     return "cover"
        case Log.ui:        return "ui"
        case Log.chapters:  return "chapters"
        case Log.zotero:     return "zotero"
        case Log.voice:      return "voice"
        case Log.characters: return "characters"
        case Log.stt:        return "stt"
        case Log.tts:        return "tts"
        case Log.semantic:   return "semantic"
        case Log.audio:      return "audio"
        case Log.search:     return "search"
        case Log.meeting:    return "meeting"
        case Log.crash:      return "crash"
        default:             return "unknown"
        }
    }
}

// MARK: - Logger+Equatable (pointer equality via identity)

extension Logger: @retroactive Equatable {
    public static func == (lhs: Logger, rhs: Logger) -> Bool {
        withUnsafePointer(to: lhs) { lp in
            withUnsafePointer(to: rhs) { rp in
                memcmp(lp, rp, MemoryLayout<Logger>.size) == 0
            }
        }
    }
}

// MARK: - LogFileWriter

/// Appends timestamped log lines to `~/OakReader/logs/oakreader.log` with simple rotation.
final class LogFileWriter {
    static let shared = LogFileWriter()

    let logFileURL: URL
    private let rotatedURL: URL
    private let queue = DispatchQueue(label: "com.oakreader.logwriter", qos: .utility)
    private var fileHandle: FileHandle?
    private let maxFileSize: UInt64 = 5 * 1024 * 1024 // 5 MB

    private lazy var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        let logsDir = CatalogDatabase.logsDirectory
        self.logFileURL = logsDir.appendingPathComponent("oakreader.log")
        self.rotatedURL = logsDir.appendingPathComponent("oakreader.1.log")
        openFile()
    }

    func write(level: String, category: String, message: String) {
        queue.async { [self] in
            let timestamp = dateFormatter.string(from: Date())
            let line = "[\(timestamp)] [\(level)] [\(category)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            rotateIfNeeded()

            if fileHandle == nil { openFile() }
            fileHandle?.seekToEndOfFile()
            fileHandle?.write(data)
        }
    }

    // MARK: Private

    private func openFile() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
    }

    private func rotateIfNeeded() {
        guard let handle = fileHandle else { return }
        let size = handle.seekToEndOfFile()
        guard size >= maxFileSize else { return }

        handle.closeFile()
        fileHandle = nil

        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: logFileURL, to: rotatedURL)

        openFile()
    }
}
