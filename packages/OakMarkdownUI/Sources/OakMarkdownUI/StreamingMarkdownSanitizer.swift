import Foundation

/// Small repairs applied ONLY to the streaming trailing block, so half-arrived
/// markdown doesn't flash an ugly intermediate state before the next token lands.
///
/// The motivating case is citations. A link streams in character by character, so for
/// a moment the block ends mid-link — `[label](oak://cite/key?page=2&text=verbat` —
/// and cmark, unable to see the closing `)`, renders the *entire raw URL as plain
/// text*. The instant `)` arrives it collapses to the short label, producing a visible
/// "long URL → pill" flicker. Optimistically closing the dangling link makes only the
/// label show, immediately and stably (the same idea as Streamdown/remend's
/// complete-incomplete-markdown pass).
enum StreamingMarkdownSanitizer {

    /// If `text` ends with an unclosed inline link/image (`…](url-with-no-closing-paren`),
    /// append the `)` so it renders as a link (label only) instead of flashing the raw
    /// URL. Returns `text` unchanged when there's nothing to close. Append-only safe:
    /// once the real `)` streams in, the last `](` is already closed and this is a no-op.
    static func completeTrailingLink(_ text: String) -> String {
        // The link being formed is always the LAST `](` in an append-only stream.
        guard let open = text.range(of: "](", options: .backwards) else { return text }
        // Must have an opening `[` for the label before the `]`.
        guard text[..<open.lowerBound].contains("[") else { return text }
        let urlFragment = text[open.upperBound...]
        // Bail if already closed, or if the fragment can't be a bare URL (a space or
        // newline means it's prose / a titled link, not a clean citation URL).
        guard !urlFragment.isEmpty,
              !urlFragment.contains(")"),
              !urlFragment.contains("("),
              !urlFragment.contains(" "),
              !urlFragment.contains("\n") else { return text }
        return text + ")"
    }
}
