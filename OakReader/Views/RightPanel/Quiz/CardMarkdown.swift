import SwiftUI
import Textual

/// Shared markdown renderer for quiz / flashcard card content.
///
/// Mirrors the chat rendering path (`ChatMarkdownBlockView`): it enables
/// Textual's `.math` syntax extension and runs `protectingMathBackslashes()`
/// first, so LaTeX (`$…$` / `$$…$$`) renders correctly. The plain
/// `StructuredText(markdown:)` calls the cards used before did neither, so
/// math was either left literal (no `.math`) or corrupted by Foundation's
/// CommonMark parser eating backslashes (no protection).
///
/// Card content is short, so no block-splitting/streaming machinery is needed
/// here — a single `StructuredText` is enough. Callers apply their own `.font`
/// / `.foregroundStyle` modifiers on top, exactly as they did with `Text`.
struct CardMarkdown: View {
    let text: String

    var body: some View {
        StructuredText(markdown: text.protectingMathBackslashes(), syntaxExtensions: [.math])
    }
}
