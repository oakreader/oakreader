import SwiftUI
import SwiftUIMath

/// Standalone display math (`$$…$$`) rendered with SwiftUIMath (already in the app graph).
struct MathBlockView: View {
    /// LaTeX body, with the surrounding `$$` already stripped.
    let latex: String
    let theme: MarkdownTheme

    var body: some View {
        Math(latex)
            .mathFont(.init(name: .latinModern, size: theme.bodyFont.pointSize + 2))
            .foregroundStyle(Color(nsColor: theme.textColor))
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
