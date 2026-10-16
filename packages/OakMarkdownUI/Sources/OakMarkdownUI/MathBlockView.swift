import SwiftUI
import SwiftUIMath

/// Standalone display math (`$$…$$`) rendered with SwiftUIMath (already in the app graph).
/// A formula SwiftUIMath cannot draw goes to KaTeX + WebKit (see `MathRoute`); until
/// that image lands, and if KaTeX fails too, the source shows as typed.
struct MathBlockView: View {
    /// LaTeX body, with the surrounding `$$` already stripped.
    let latex: String
    let theme: MarkdownTheme

    private var fontSize: CGFloat { theme.bodyFont.pointSize + 2 }

    var body: some View {
        Group {
            if MathRoute.nativeCanDraw(latex, display: true, fontSize: fontSize) {
                Math(MarkdownCompat.normalizeLaTeX(latex))
                    .mathFont(.init(name: .latinModern, size: fontSize))
                    .foregroundStyle(Color(nsColor: theme.textColor))
            } else if case .ready(let rendered) = MathMLRenderer.shared.lookup(
                latex: latex, display: true, fontSize: fontSize, color: theme.textColor) {
                Image(nsImage: rendered.image)
            } else {
                Text("$$\(latex)$$")
                    .font(Font(theme.codeFont))
                    .foregroundStyle(Color(nsColor: theme.secondaryTextColor))
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// A display formula whose closing `$$` has not arrived. Draws the longest prefix
/// that parses (see `StreamingMath`); before any prefix parses, it holds one line
/// of space so the source never flashes.
struct StreamingMathBlockView: View {
    /// LaTeX received so far, with the opening `$$` stripped.
    let latex: String
    let theme: MarkdownTheme

    private var fontSize: CGFloat { theme.bodyFont.pointSize + 2 }

    var body: some View {
        Group {
            if let drawable = StreamingMath.drawablePrefix(latex, fontSize: fontSize) {
                Math(MarkdownCompat.normalizeLaTeX(drawable))
                    .mathFont(.init(name: .latinModern, size: fontSize))
                    .foregroundStyle(Color(nsColor: theme.textColor))
            } else {
                Color.clear.frame(height: ceil(fontSize * 1.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}
