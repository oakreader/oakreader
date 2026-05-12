import Foundation

/// Truncation logic for tool output.
public enum OutputTruncation {
    /// Truncate text to a maximum character count, appending a truncation notice.
    public static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)) + "\n\n[Truncated at \(maxLength) characters]"
    }
}
