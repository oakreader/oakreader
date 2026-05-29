import Foundation
import Darwin

/// On-disk agent workspaces under `<dataDir>/workspace/`.
///
/// A workspace is a real folder the AI agent uses as its working directory. The
/// bound content's source files are *mounted* into it via APFS copy-on-write
/// clones (`clonefile`): the workspace gets an independent, editable copy that
/// shares storage with the library original until modified — instant, ~zero disk
/// cost, and the agent's edits never touch the managed original.
enum AgentWorkspace {
    /// What the workspace is scoped to.
    enum Binding: Equatable {
        case general
        case collection(id: UUID)
        case item(storageKey: String)
    }

    /// `<dataDir>/workspace/`
    static var root: URL {
        CatalogDatabase.dataDirectory.appendingPathComponent("workspace", isDirectory: true)
    }

    /// The folder for a binding (not necessarily created yet).
    static func directory(for binding: Binding) -> URL {
        switch binding {
        case .general:
            return root.appendingPathComponent("general", isDirectory: true)
        case .collection(let id):
            return root.appendingPathComponent("collections", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
        case .item(let storageKey):
            return root.appendingPathComponent("items", isDirectory: true)
                .appendingPathComponent(storageKey, isDirectory: true)
        }
    }

    /// Create the workspace folder synchronously (cheap) and return its URL.
    @discardableResult
    static func ensureDirectory(for binding: Binding) -> URL {
        let dir = directory(for: binding)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// CoW-clone the given source files into `directory`, skipping any that
    /// already exist so the agent's working copies are preserved across sessions.
    static func mountSources(_ sources: [URL], into directory: URL) {
        let fm = FileManager.default
        var usedNames = Set<String>()
        for src in sources {
            guard fm.fileExists(atPath: src.path) else { continue }
            var name = src.lastPathComponent
            // Disambiguate identical filenames coming from different items.
            if usedNames.contains(name.lowercased()) {
                let base = src.deletingPathExtension().lastPathComponent
                let ext = src.pathExtension
                let suffix = String(UUID().uuidString.prefix(4))
                name = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
            }
            usedNames.insert(name.lowercased())

            let dst = directory.appendingPathComponent(name)
            guard !fm.fileExists(atPath: dst.path) else { continue }
            cloneOrCopy(from: src, to: dst)
        }
    }

    /// APFS copy-on-write clone; falls back to a plain copy across volumes or
    /// on non-APFS filesystems where `clonefile` is unavailable.
    private static func cloneOrCopy(from src: URL, to dst: URL) {
        let cloned = src.withUnsafeFileSystemRepresentation { s -> Bool in
            guard let s else { return false }
            return dst.withUnsafeFileSystemRepresentation { d -> Bool in
                guard let d else { return false }
                return clonefile(s, d, 0) == 0
            }
        }
        if !cloned {
            try? FileManager.default.copyItem(at: src, to: dst)
        }
    }
}
