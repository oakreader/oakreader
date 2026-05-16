import SwiftUI

/// List of saved flashcards for the current document, grouped by quiz type.
struct FlashcardListView: View {
    let flashcardsVM: FlashcardsViewModel

    var body: some View {
        List {
            ForEach(flashcardsVM.groupedByType, id: \.key) { group in
                Section {
                    ForEach(group.cards) { card in
                        cardRow(card)
                    }
                } header: {
                    Label(group.key.label, systemImage: group.key.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func cardRow(_ card: QuizCard) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.displayTitle)
                    .font(.system(size: 13))
                    .lineLimit(2)

                HStack(spacing: 6) {
                    stateLabel(card.state)

                    if card.isDue {
                        Text("Due")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                    } else if card.state != .new {
                        Text("in \(card.scheduledDays)d")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    if card.isSuspended {
                        Image(systemName: "pause.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Suspend") {
                flashcardsVM.toggleSuspend(card)
            }
            Divider()
            Button("Delete", role: .destructive) {
                flashcardsVM.deleteCard(card)
            }
        }
    }

    @ViewBuilder
    private func stateLabel(_ state: CardState) -> some View {
        let (text, color): (String, Color) = switch state {
        case .new: ("New", .blue)
        case .learning: ("Learning", .orange)
        case .review: ("Review", .green)
        case .relearning: ("Relearning", .red)
        }
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
    }
}
