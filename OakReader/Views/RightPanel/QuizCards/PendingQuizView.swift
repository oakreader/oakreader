import SwiftUI

/// Shows pending quiz cards allowing user review before scheduling.
/// Displays a single card at a time in an Anki-style centered preview.
struct PendingQuizView: View {
    let quizCardsVM: QuizCardsViewModel
    @State private var currentIndex: Int = 0

    private var pendingCards: [QuizCard] {
        quizCardsVM.pendingCards
    }

    private var currentCard: QuizCard? {
        guard !pendingCards.isEmpty, currentIndex < pendingCards.count else { return nil }
        return pendingCards[currentIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if pendingCards.isEmpty {
                emptyState
            } else {
                cardPreview
                actionBar
            }
        }
        .onChange(of: pendingCards.count) { _, newCount in
            if currentIndex >= newCount {
                currentIndex = max(0, newCount - 1)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Pending Review")
                .font(.system(size: 14, weight: .semibold))

            Text("\(quizCardsVM.pendingCount)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.purple))

            if !pendingCards.isEmpty {
                Text("\(currentIndex + 1) / \(pendingCards.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if quizCardsVM.pendingCount > 0 {
                Button("Save All") {
                    quizCardsVM.approveAllPending()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Approve all pending cards")
            }
        }
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.xs)
    }

    // MARK: - Card Preview

    private var cardPreview: some View {
        VStack(spacing: 0) {
            if let card = currentCard {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Type badge
                        HStack(spacing: 6) {
                            Image(systemName: card.type.systemImage)
                                .font(.system(size: 12))
                                .foregroundStyle(.purple)
                            Text(card.type.label)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.purple)
                        }

                        // Card content adapts by type
                        QuizCardPreviewContent(content: card.content)
                    }
                    .padding(20)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                )
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.vertical, OakStyle.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            // Navigation arrows
            Button {
                if currentIndex > 0 { currentIndex -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(currentIndex == 0)

            Button {
                if currentIndex < pendingCards.count - 1 { currentIndex += 1 }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(currentIndex >= pendingCards.count - 1)

            Spacer()

            // Save / Delete
            if let card = currentCard {
                Button(role: .destructive) {
                    quizCardsVM.deletePendingCard(card)
                } label: {
                    Label("Delete", systemImage: "trash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    quizCardsVM.approveCard(card)
                } label: {
                    Label("Save", systemImage: "checkmark.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.green)
            }
        }
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.xs)
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
            Text("Select text and tap the sparkles button to generate quiz cards.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, OakStyle.Spacing.lg)
            Spacer()
        }
    }
}
