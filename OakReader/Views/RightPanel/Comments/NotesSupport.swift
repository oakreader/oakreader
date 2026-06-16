import SwiftUI

/// flomo-style `#tag` handling — extract hierarchical hashtags (`#welcome/guide`,
/// `#tags/sub-tags`, CJK supported) for chip display and strip them from the body
/// so the rendered markdown doesn't show raw `#…` runs.
enum NoteTags {
    // A `#` at a token boundary, followed by a tag path. Lookbehind keeps it from
    // matching inside words/URLs (e.g. `foo#bar`, `http://x#y`).
    // swiftlint:disable:next force_try
    private static let regex = try! NSRegularExpression(
        pattern: #"(?<!\S)#([\p{L}\p{N}_][\p{L}\p{N}_/-]*)"#
    )

    /// Unique tag paths (without the leading `#`), in first-seen order.
    static func extract(_ text: String) -> [String] {
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1))
            if seen.insert(tag).inserted { out.append(tag) }
        }
        return out
    }

    /// The note body with hashtags removed and whitespace tidied, for rendering.
    static func strippedBody(_ text: String) -> String {
        let ns = text as NSString
        let stripped = regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: ""
        )
        let lines = stripped.components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A flomo `#tag` chip — lavender fill, blue text.
struct NoteTagChip: View {
    let tag: String
    var body: some View {
        Text("#\(tag)")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(Color.accentColor.opacity(0.10))
            )
    }
}
