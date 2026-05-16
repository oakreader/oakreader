import SwiftUI

/// Container view for the Flashcards right panel. Switches between list and review mode.
struct FlashcardsPanelView: View {
    let flashcardsVM: FlashcardsViewModel

    var body: some View {
        VStack(spacing: 0) {
            if flashcardsVM.isReviewing {
                FlashcardReviewView(flashcardsVM: flashcardsVM)
            } else {
                cardListContainer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cardListContainer: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Flashcards")
                    .font(.system(size: 16, weight: .semibold))

                if flashcardsVM.dueCount > 0 {
                    Text("\(flashcardsVM.dueCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }

                Spacer()

                if flashcardsVM.dueCount > 0 {
                    Button(action: { flashcardsVM.startReview() }) {
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

            if flashcardsVM.cards.isEmpty {
                emptyState
            } else {
                FlashcardListView(flashcardsVM: flashcardsVM)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No Flashcards Yet")
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
