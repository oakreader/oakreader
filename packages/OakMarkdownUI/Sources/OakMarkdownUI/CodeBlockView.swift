import SwiftUI
import AppKit
import Highlightr

/// Fenced code block: Highlightr syntax highlighting + a header (language + Copy),
/// horizontally scrollable, on a subtle filled/bordered surface (Dia-style).
struct CodeBlockView: View {
    let code: String
    let language: String?
    let theme: MarkdownTheme
    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language?.isEmpty == false ? language! : "code"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: copy) {
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider().opacity(0.5)

            ScrollView(.horizontal, showsIndicators: false) {
                CodeTextView(attributed: highlighted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        .background(Color(nsColor: theme.codeBlockBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: theme.codeBlockBorder), lineWidth: 1)
        )
    }

    private var highlighted: NSAttributedString {
        guard let hl = Highlightr() else {
            return NSAttributedString(string: code, attributes: [.font: theme.codeFont])
        }
        hl.setTheme(to: colorScheme == .dark ? theme.codeThemeDark : theme.codeThemeLight)
        let result = hl.highlight(code, as: language) ?? NSAttributedString(string: code)
        return result
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

/// Non-editable, non-wrapping NSTextView for code (lets the ScrollView scroll horizontally).
private struct CodeTextView: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView()
        tv.isEditable = false
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isHorizontallyResizable = true
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        if tv.textStorage?.isEqual(to: attributed) != true {
            tv.textStorage?.setAttributedString(attributed)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView tv: NSTextView, context: Context) -> CGSize? {
        guard let container = tv.textContainer, let lm = tv.layoutManager else { return nil }
        lm.ensureLayout(for: container)
        let used = lm.usedRect(for: container)
        return CGSize(width: ceil(used.width), height: ceil(used.height))
    }
}
