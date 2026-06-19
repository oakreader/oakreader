import SwiftUI

/// flomo-style `#tag` handling — extract hierarchical hashtags (`#welcome/guide`,
/// `#tags/sub-tags`, CJK supported) for chip display and strip them from the body
/// so the rendered markdown doesn't show raw `#…` runs.
enum NoteTags {
    // A `#` at a token boundary, followed by a tag path. Lookbehind keeps it from
    // matching inside words/URLs (e.g. `foo#bar`, `http://x#y`). The optional `\`
    // absorbs the commonmark escape Milkdown writes for a leading `#` (`\#tag`),
    // which would otherwise be a non-whitespace char that defeats the lookbehind.
    // swiftlint:disable:next force_try
    private static let regex = try! NSRegularExpression(
        pattern: #"(?<!\S)\\?#([\p{L}\p{N}_][\p{L}\p{N}_/-]*)"#
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

    // Collapse markdown links `[label](url)` to just their label, so a plain-text
    // preview never shows raw `(oak://note/…)` URL noise.
    // swiftlint:disable:next force_try
    private static let linkRegex = try! NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#)

    /// A clean, single-line plain-text preview of a note body for pickers / backlinks:
    /// drops `#tags`, collapses markdown links to their label, and tidies whitespace.
    static func preview(_ text: String) -> String {
        let noTags = strippedBody(text)
        let ns = noTags as NSString
        let collapsed = linkRegex.stringByReplacingMatches(
            in: noTags, range: NSRange(location: 0, length: ns.length), withTemplate: "$1"
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
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

/// A memo the `@` reference picker can link to (flomo-style note-to-note link).
struct NoteRef: Identifiable, Hashable {
    let id: String
    let preview: String
    let time: String
}

/// A note-to-note `@` reference link. Follows the app's `oak://<type>/…` scheme
/// convention (cf. `oak://cite/…`, `oak://page/N`): a note reference is
/// `oak://note/<annotationId>`.
enum NoteLink {
    static func href(_ id: String) -> String { "oak://note/\(id)" }

    /// The referenced annotation id from an `oak://note/<id>` URL, or nil.
    static func id(from url: URL) -> String? {
        guard url.scheme == "oak", url.host == "note" else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return id.isEmpty ? nil : id
    }
}

/// Shared timestamp formatting for note cards / pickers. `created_at` is stored
/// with fractional seconds (CatalogDatabase), so the parser must opt into them;
/// older rows without them fall back to the plain form.
enum NoteTime {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static let display: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static func absolute(_ iso: String) -> String {
        guard let date = isoFractional.date(from: iso) ?? isoPlain.date(from: iso) else { return "" }
        return display.string(from: date)
    }
}

/// A flomo `#tag` chip — lavender fill, blue text. When `action` is set it's a
/// button that filters the note stream by this tag; `isActive` paints it solid
/// to show it's the current filter.
struct NoteTagChip: View {
    let tag: String
    var isActive: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
                .help(isActive ? "Show all notes" : "Show only notes tagged #\(tag)")
        } else {
            chip
        }
    }

    private var chip: some View {
        Text("#\(tag)")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isActive ? Color.white : Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(isActive ? Color.accentColor : Color.accentColor.opacity(0.10))
            )
            .contentShape(Capsule())
    }
}
