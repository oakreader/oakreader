import SwiftUI

/// Per-item right-panel surface listing every quiz card the AI generated for
/// this document, grouped by the conversation that produced it. Read-only — the
/// cards live in chat history; this is just a convenient place to review them
/// all without scrolling each chat. No saving, no editing, no export.
struct ItemQuizCardsPanelView: View {
    let viewModel: DocumentViewModel

    private var model: ItemQuizCardsViewModel { viewModel.quizCards }

    var body: some View {
        VStack(spacing: 0) {
            panelHeader("Quiz Cards", subtitle: subtitle)

            if !model.isLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.sections.isEmpty {
                emptyState(
                    icon: "rectangle.on.rectangle.angled",
                    title: "No Quiz Cards Yet",
                    subtitle: "Ask the AI to quiz you in chat. Cards generated for this document show up here, grouped by conversation."
                )
            } else {
                cardList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: viewModel.itemId) { await model.reload() }
    }

    private var subtitle: String {
        guard model.isLoaded else { return " " }
        let cards = model.totalCards
        let chats = model.sections.count
        if cards == 0 { return "No cards" }
        return "\(cards) card\(cards == 1 ? "" : "s") · \(chats) chat\(chats == 1 ? "" : "s")"
    }

    private var cardList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                ForEach(model.sections) { section in
                    VStack(alignment: .leading, spacing: 14) {
                        // A quiet date label only earns its place when more than
                        // one conversation produced cards; otherwise the panel
                        // subtitle ("N cards · 1 chat") already says it.
                        if model.sections.count > 1 {
                            Text(section.date, format: .dateTime.month().day().year())
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 2)
                        }
                        ForEach(Array(section.decks.enumerated()), id: \.offset) { _, deck in
                            InlineDeckView(deck: deck)
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
        }
    }
}
