import SwiftUI
import AppKit
import OakMarkdownUI

/// Read-only markdown preview for `.md`/`.markdown` files opened as tabs.
/// No editor, no mode toggle — a single centered scroll column rendered via
/// the same engine the chat uses.
struct MarkdownPreviewView: View {
    let viewModel: DocumentViewModel

    var body: some View {
        ScrollView(.vertical) {
            StreamingMarkdownView(
                markdown: viewModel.markdownDocument?.content ?? "",
                theme: .oak(),
                isStreaming: false,
                onOpenURL: { url in
                    NSWorkspace.shared.open(url)
                    return true
                }
            )
            .textSelection(.enabled)
            .frame(maxWidth: 780)
            .padding(.horizontal, 48)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
