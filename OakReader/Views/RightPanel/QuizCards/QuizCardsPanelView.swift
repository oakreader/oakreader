import SwiftUI

/// Container view for the Quiz Cards right panel. Switches between list and review mode.
struct QuizCardsPanelView: View {
    let quizCardsVM: QuizCardsViewModel

    var body: some View {
        VStack(spacing: 0) {
            cardListContainer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cardListContainer: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Quiz Cards")
                    .font(.system(size: 16, weight: .semibold))

                if quizCardsVM.dueCount > 0 {
                    Text("\(quizCardsVM.dueCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }

                Spacer()

                if quizCardsVM.dueCount > 0 {
                    Button(action: { quizCardsVM.startReview() }) {
                        Label("Review", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Start review session")
                }
            }
            .padding(.horizontal, OakStyle.Spacing.sm)
            .padding(.vertical, OakStyle.Spacing.sm)

            // Pending cards section (shown above the main list when present)
            if quizCardsVM.pendingCount > 0 {
                PendingQuizView(quizCardsVM: quizCardsVM)
                    .frame(maxHeight: 300)
                Divider()
            }

            if quizCardsVM.cards.isEmpty && quizCardsVM.pendingCount == 0 {
                emptyState
            } else if !quizCardsVM.cards.isEmpty {
                QuizCardListView(quizCardsVM: quizCardsVM)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No Quiz Cards Yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Use the /quiz skill in chat to generate quiz cards, then save the ones you want to review.")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, OakStyle.Spacing.lg)
            Spacer()
        }
    }
}
