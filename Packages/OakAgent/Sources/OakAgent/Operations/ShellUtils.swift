import Foundation

/// Single-quote a string for safe use in shell commands.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
