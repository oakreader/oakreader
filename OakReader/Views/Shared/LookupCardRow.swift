import SwiftUI
import OakMarkdownUI

/// A saved word lookup shown like a flashcard: collapsed it shows the word and
/// the context sentence (with the word highlighted) — the "front"; tap to reveal
/// the saved explanation — the "back". Used by both the per-document Translation
/// history and the global Words view. No spaced repetition; just review.
struct LookupCardRow: View {
    let lookup: WordLookup
    /// Show the source document title (used in the global Words view).
    var showDocTitle: Bool = false
    var onDelete: (() -> Void)? = nil

    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: revealed ? 8 : 4) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { revealed.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lookup.word)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                        StreamingMarkdownView(markdown: lookup.frontMarkdown, theme: .oak(fontSize: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if showDocTitle, !lookup.itemTitle.isEmpty {
                            Label(lookup.itemTitle, systemImage: "doc")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(revealed ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if revealed {
                Divider()
                StreamingMarkdownView(markdown: lookup.explanation, theme: .oak(fontSize: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.05), lineWidth: 1))
        .contextMenu {
            if let onDelete {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}
