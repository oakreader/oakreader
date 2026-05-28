import SwiftUI

// The bottom action bar (show-answer / rating buttons) and the leech banner for
// the review session. Split out of QuizCardReviewView.swift for readability;
// behaviour is unchanged. `actionArea` and `leechBanner` are the entry points
// called by the session shell, so they are `internal`; the rest stays `private`.
extension QuizCardReviewView {

    // MARK: - Action Area

    var actionArea: some View {
        Group {
            if isRevealed {
                if ratingButtonCount == 4 {
                    fourButtonArea
                } else {
                    twoButtonArea
                }
            } else {
                showAnswerButton
            }
        }
    }

    private var showAnswerButton: some View {
        Button {
            withAnimation(.spring(duration: 0.35, bounce: 0.15)) { isRevealed = true }
        } label: {
            HStack(spacing: 6) {
                Text("Show Answer")
                    .font(.system(size: 14, weight: .semibold))
                Text("Space")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rating Buttons

    private var twoButtonArea: some View {
        HStack(spacing: 10) {
            ratingButton(label: "Forget", key: "1", rating: .again, tint: Color(hex: "ff375b"))
            ratingButton(label: "Remember", key: "2", rating: .good, tint: Color(hex: "199d00"))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var fourButtonArea: some View {
        HStack(spacing: 8) {
            ratingButton(label: "Again", key: "1", rating: .again, tint: Color(hex: "ff375b"))
            ratingButton(label: "Hard", key: "2", rating: .hard, tint: Color(hex: "fb5825"))
            ratingButton(label: "Good", key: "3", rating: .good, tint: Color(hex: "199d00"))
            ratingButton(label: "Easy", key: "4", rating: .easy, tint: Color(hex: "009dff"))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func ratingButton(label: String, key: String, rating: ReviewRating, tint: Color) -> some View {
        Button {
            quizCardsVM.submitReview(rating: rating)
        } label: {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                Text(key)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint.opacity(0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(tint.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onKeyPress(KeyEquivalent(key.first!)) {
            quizCardsVM.submitReview(rating: rating)
            return .handled
        }
    }

    // MARK: - Leech Banner

    func leechBanner(_ card: QuizCard) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This card is a leech (\(card.lapses) lapses)")
                        .font(.system(size: 13, weight: .semibold))
                    if autoSuspendLeech {
                        Text("Card has been auto-suspended")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    if !card.isSuspended {
                        quizCardsVM.toggleSuspend(card)
                    }
                    quizCardsVM.dismissLeechAlert()
                } label: {
                    Text("Suspend")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(card.isSuspended)

                Button {
                    quizCardsVM.regenerateCard(card)
                } label: {
                    Text("Regenerate")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    quizCardsVM.deleteCard(card)
                    quizCardsVM.dismissLeechAlert()
                } label: {
                    Text("Delete")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    quizCardsVM.dismissLeechAlert()
                } label: {
                    Text("Continue")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
    }
}
