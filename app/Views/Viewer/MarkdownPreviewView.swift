import SwiftUI
import AppKit
import OakMarkdownUI

/// Read-only markdown preview for `.md`/`.markdown` files opened as tabs.
/// No editor, no mode toggle — a single centered scroll column rendered via
/// the same engine the chat uses.
struct MarkdownPreviewView: View {
    let viewModel: DocumentViewModel

    @State private var scrollPosition = ScrollPosition()

    /// Where the column is scrolled to, and how far it can scroll.
    private struct ScrollMetrics: Equatable {
        var offset: CGFloat
        var maxOffset: CGFloat
    }

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
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
            ScrollMetrics(
                offset: geometry.contentOffset.y,
                maxOffset: max(0, geometry.contentSize.height - geometry.containerSize.height)
            )
        } action: { _, metrics in
            guard metrics.maxOffset > 0 else { return }
            // The first time the column can scroll, return to where the reader left off.
            if let fraction = viewModel.pendingRestorePosition {
                viewModel.pendingRestorePosition = nil
                scrollPosition.scrollTo(y: min(max(fraction, 0), 1) * metrics.maxOffset)
                return
            }
            viewModel.recordReadingPosition(metrics.offset / metrics.maxOffset)
        }
        .background(OakStyle.Surface.card)
    }
}
