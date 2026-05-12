import Foundation

/// Protocol for directory listing (pluggable for testing).
public protocol LsOperations: Sendable {
    func listDirectory(at url: URL) throws -> [LsEntry]
}

/// A single directory entry.
public struct LsEntry: Sendable {
    public let name: String
    public let isDirectory: Bool
    public let size: UInt64?

    public init(name: String, isDirectory: Bool, size: UInt64? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
    }
}

/// Default local directory listing implementation.
public struct LocalLsOperations: LsOperations, Sendable {
    public init() {}

    public func listDirectory(at url: URL) throws -> [LsEntry] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])

        return contents.compactMap { itemURL in
            let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDir = resourceValues?.isDirectory ?? false
            let size = resourceValues?.fileSize.map { UInt64($0) }
            return LsEntry(name: itemURL.lastPathComponent, isDirectory: isDir, size: size)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
