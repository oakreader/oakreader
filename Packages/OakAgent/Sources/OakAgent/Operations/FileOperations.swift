import Foundation

/// Protocol for file I/O operations (pluggable for testing).
public protocol FileOperations: Sendable {
    func readFile(at url: URL) throws -> String
    func writeFile(content: String, to url: URL) throws
    func fileExists(at path: String) -> Bool
    func createDirectory(at url: URL) throws
}

/// Default local file system implementation.
public struct LocalFileOperations: FileOperations, Sendable {
    public init() {}

    public func readFile(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    public func writeFile(content: String, to url: URL) throws {
        let parentDir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    public func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
