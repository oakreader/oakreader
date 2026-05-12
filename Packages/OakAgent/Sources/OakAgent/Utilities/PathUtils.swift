import Foundation

/// Path resolution and normalization utilities.
public enum PathUtils {
    /// Resolve a path that may be relative, using the given base directory.
    public static func resolve(_ path: String, base: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardized
        }
        return base.appendingPathComponent(path).standardized
    }

    /// Normalize a path by resolving `.` and `..` components.
    public static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardized.path
    }
}
