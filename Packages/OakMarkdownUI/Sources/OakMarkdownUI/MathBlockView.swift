import SwiftUI
import AppKit
import SwiftMath

/// Standalone display math (`$$…$$`) rendered with SwiftMath's MTMathUILabel (CoreText),
/// the same engine Dia uses.
struct MathBlockView: NSViewRepresentable {
    /// LaTeX body, with the surrounding `$$` already stripped.
    let latex: String
    let theme: MarkdownTheme

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        label.textAlignment = .center
        label.labelMode = .display
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        label.fontSize = theme.bodyFont.pointSize + 2
        label.textColor = theme.textColor
        label.latex = latex
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView label: MTMathUILabel, context: Context) -> CGSize? {
        label.fontSize = theme.bodyFont.pointSize + 2
        label.latex = latex
        let fitting = label.intrinsicContentSize
        let width = proposal.width ?? fitting.width
        return CGSize(width: width, height: ceil(max(fitting.height, label.fontSize * 1.6)))
    }
}
