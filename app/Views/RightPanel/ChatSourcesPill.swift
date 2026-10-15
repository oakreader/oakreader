import SwiftUI

/// The passages one answer cites, grouped by document.
struct ChatCitedSources {
    struct Passage: Identifiable {
        let id: Int
        let anchor: CitationAnchor
    }

    struct Document: Identifiable {
        let id: String
        let title: String
        var passages: [Passage]
    }

    let documents: [Document]

    var passageCount: Int { documents.reduce(0) { $0 + $1.passages.count } }

    /// Every `oak:N` the answer cites, in the order it first cites them.
    ///
    /// Read from the text, not from the conversation's source table: the table
    /// holds every passage the model was shown, and the pill is about what this
    /// answer actually used.
    init(markdown: String,
         resolve: (URL) -> (itemId: String, anchor: CitationAnchor)?,
         title: (String) -> String?) {
        var seen = Set<Int>()
        var docs: [Document] = []
        let ns = markdown as NSString
        let re = try? NSRegularExpression(pattern: "oak:([0-9]+)\\b")
        for m in re?.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) ?? [] {
            guard let n = Int(ns.substring(with: m.range(at: 1))), seen.insert(n).inserted,
                  let url = URL(string: "oak:\(n)"), let (itemId, anchor) = resolve(url) else { continue }
            let passage = Passage(id: n, anchor: anchor)
            if let index = docs.firstIndex(where: { $0.id == itemId }) {
                docs[index].passages.append(passage)
            } else {
                docs.append(Document(id: itemId, title: title(itemId) ?? "Untitled", passages: [passage]))
            }
        }
        documents = docs
    }
}

/// "Sources" under an answer that cites passages: ChatGPT's `MessageSourcesView`
/// pill, opening to the list of what was cited. The inline citations stay quiet
/// in the text; this is where the reader goes to see all of them at once.
struct ChatSourcesPill: View {
    let sources: ChatCitedSources
    var onOpen: (String, CitationAnchor) -> Void

    @State private var isPresented = false
    @State private var isHovered = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                Text("Sources")
                    .font(.system(size: 12, weight: .medium))
                Text("\(sources.passageCount)")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                // ChatGPT's `OneOff/CitationButtonBackgroundMac`: 5 % ink, 10 % in dark.
                Capsule().fill(Color.primary.opacity(isHovered ? 0.09 : 0.05))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            list
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(sources.documents) { doc in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(doc.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(2)
                        ForEach(doc.passages) { passage in
                            Button {
                                isPresented = false
                                onOpen(doc.id, passage.anchor)
                            } label: {
                                PassageRow(anchor: passage.anchor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 320)
        .frame(maxHeight: 420)
    }
}

private struct PassageRow: View {
    let anchor: CitationAnchor
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(CitationHoverCard.locationLabel(for: anchor))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if let text = anchor.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(isHovered ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}
