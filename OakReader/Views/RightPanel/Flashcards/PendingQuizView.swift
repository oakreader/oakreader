import SwiftUI

/// Shows pending quiz cards generated from highlights, allowing user review before scheduling.
struct PendingQuizView: View {
    let flashcardsVM: FlashcardsViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            if flashcardsVM.pendingCards.isEmpty {
                emptyState
            } else {
                cardList
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Pending Review")
                .font(.system(size: 14, weight: .semibold))

            Text("\(flashcardsVM.pendingCount)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.purple))

            Spacer()

            if flashcardsVM.pendingCount > 0 {
                Button("Save All") {
                    flashcardsVM.approveAllPending()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Approve all pending cards")
            }
        }
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.xs)
    }

    // MARK: - Card List

    private var cardList: some View {
        List {
            ForEach(flashcardsVM.pendingCards) { card in
                pendingCardRow(card)
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func pendingCardRow(_ card: QuizCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Type badge
            HStack(spacing: 4) {
                Image(systemName: card.type.systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(.purple)
                Text(card.type.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.purple)
                Spacer()
            }

            // Card preview
            Text(card.displayTitle)
                .font(.system(size: 13))
                .lineLimit(3)

            // Source text excerpt
            if let source = card.sourceText {
                Text(source.prefix(80) + (source.count > 80 ? "…" : ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            // Action buttons
            HStack(spacing: 8) {
                Button {
                    flashcardsVM.approveCard(card)
                } label: {
                    Label("Save", systemImage: "checkmark.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.green)

                Button(role: .destructive) {
                    flashcardsVM.deletePendingCard(card)
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No Pending Cards")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Select text and tap the sparkles button to generate quiz cards from highlights.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, OakStyle.Spacing.lg)
            Spacer()
        }
    }
}
