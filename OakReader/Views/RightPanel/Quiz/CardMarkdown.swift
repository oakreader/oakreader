import SwiftUI
import OakMarkdownUI

/// Shared markdown renderer for quiz / flashcard card content.
///
/// Uses the same native renderer as chat (`StreamingMarkdownView`), so cards and chat
/// render identically — math (`$…$` / `$$…$$`), code, and bold/quote styling all match.
/// Sizing comes from the `MarkdownTheme` rather than a SwiftUI `.font`, so callers pass
/// `fontSize` instead of applying `.font` on top.
struct CardMarkdown: View {
    let text: String
    var fontSize: CGFloat = 15
    /// Intercepts link clicks (e.g. `oak://cite/…` citations). Return `true` if
    /// handled, `false` to let the system open the URL.
    var onOpenURL: ((URL) -> Bool)? = nil

    var body: some View {
        StreamingMarkdownView(markdown: text, theme: .oak(fontSize: fontSize), onOpenURL: onOpenURL)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
