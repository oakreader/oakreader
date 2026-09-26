import Foundation

/// Path validation utilities for sandboxed tool execution.
public enum PathSandbox {
    /// Returns a validated, standardized file URL if the path is within allowed directories.
    /// Returns nil if the path escapes the sandbox.
    public static func validate(path: String, allowedPaths: [URL]) -> URL? {
        // If no allowed paths, allow everything
        if allowedPaths.isEmpty {
            return URL(fileURLWithPath: path).standardized
        }

        let url = URL(fileURLWithPath: path).standardized

        for allowed in allowedPaths {
            let allowedPath = allowed.standardized.path
            if url.path.hasPrefix(allowedPath) {
                return url
            }
        }
        return nil
    }

    /// Resolve a potentially relative path against the working directory.
    public static func resolve(path: String, workingDirectory: URL) -> String {
        if path.hasPrefix("/") {
            return path
        }
        return workingDirectory.appendingPathComponent(path).standardized.path
    }
}
