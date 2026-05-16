import SwiftUI
import Textual

/// Review session: displays the current card and Again/Hard/Good/Easy buttons.
struct FlashcardReviewView: View {
    let flashcardsVM: FlashcardsViewModel

    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { flashcardsVM.endReview() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("End review")

                Spacer()

                Text("\(flashcardsVM.currentReviewIndex + 1) / \(flashcardsVM.dueCards.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()

                // Progress
                ProgressView(value: Double(flashcardsVM.currentReviewIndex), total: Double(flashcardsVM.dueCards.count))
                    .frame(width: 80)
            }
            .padding(.horizontal, OakStyle.Spacing.sm)
            .padding(.vertical, OakStyle.Spacing.xs)

            Divider()

            // Card content
            if let card = flashcardsVM.currentReviewCard {
                ScrollView {
                    VStack(spacing: 16) {
                        cardContent(card)
                    }
                    .padding(OakStyle.Spacing.md)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Rating buttons
                if isRevealed {
                    ratingButtons
                        .padding(.horizontal, OakStyle.Spacing.sm)
                        .padding(.vertical, OakStyle.Spacing.sm)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    showAnswerButton
                        .padding(.horizontal, OakStyle.Spacing.sm)
                        .padding(.vertical, OakStyle.Spacing.sm)
                }
            } else {
                // Review complete
                reviewCompleteView
            }
        }
        .onChange(of: flashcardsVM.currentReviewIndex) { _, _ in
            isRevealed = false
        }
    }

    // MARK: - Card Content

    @ViewBuilder
    private func cardContent(_ card: QuizCard) -> some View {
        switch card.content {
        case .flashcard(let c):
            VStack(alignment: .leading, spacing: 12) {
                Text("Front")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                StructuredText(markdown: c.front)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isRevealed {
                    Divider()
                    Text("Back")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    StructuredText(markdown: c.back)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

        case .cloze(let c):
            VStack(alignment: .leading, spacing: 8) {
                if isRevealed {
                    // Show full text with answers highlighted
                    StructuredText(markdown: revealCloze(c.text))
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Show text with blanks
                    StructuredText(markdown: hideCloze(c.text))
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let hint = c.hint {
                        Text("Hint: \(hint)")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

        case .choice(let c):
            VStack(alignment: .leading, spacing: 12) {
                StructuredText(markdown: c.question)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(Array(c.choices.enumerated()), id: \.offset) { idx, choice in
                    HStack(spacing: 8) {
                        Image(systemName: isRevealed && idx == c.correctIndex ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isRevealed && idx == c.correctIndex ? .green : .secondary)
                        Text(choice)
                            .font(.system(size: 13))
                    }
                    .padding(.vertical, 4)
                }

                if isRevealed, let explanation = c.explanation {
                    Divider()
                    Text(explanation)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

        case .matching(let c):
            VStack(alignment: .leading, spacing: 8) {
                Text("Match the pairs:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                ForEach(Array(c.pairs.enumerated()), id: \.offset) { _, pair in
                    HStack {
                        Text(pair.left)
                            .font(.system(size: 13))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if isRevealed {
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                            Text(pair.right)
                                .font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("???")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

        case .ordering(let c):
            VStack(alignment: .leading, spacing: 8) {
                StructuredText(markdown: c.prompt)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isRevealed {
                    ForEach(Array(c.items.enumerated()), id: \.offset) { idx, item in
                        HStack(spacing: 8) {
                            Text("\(idx + 1).")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .trailing)
                            Text(item)
                                .font(.system(size: 13))
                        }
                    }
                } else {
                    Text("Tap 'Show Answer' to see the correct order")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }

        case .occlusion:
            Text("Image occlusion review not yet supported.")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Cloze Helpers

    private func hideCloze(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\{\{c\d+::([^}]*?)(?:::[^}]*)?\}\}"#,
            with: "[___]",
            options: .regularExpression
        )
    }

    private func revealCloze(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\{\{c\d+::([^}]*?)(?:::[^}]*)?\}\}"#,
            with: "**$1**",
            options: .regularExpression
        )
    }

    // MARK: - Buttons

    private var showAnswerButton: some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isRevealed = true } }) {
            Text("Show Answer")
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var ratingButtons: some View {
        HStack(spacing: 8) {
            ForEach(ReviewRating.allCases, id: \.rawValue) { rating in
                Button(action: { flashcardsVM.submitReview(rating: rating) }) {
                    Text(rating.label)
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(ratingColor(rating))
                .controlSize(.regular)
            }
        }
    }

    private func ratingColor(_ rating: ReviewRating) -> Color {
        switch rating {
        case .again: return .red
        case .hard: return .orange
        case .good: return .green
        case .easy: return .blue
        }
    }

    // MARK: - Review Complete

    private var reviewCompleteView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text("Review Complete")
                .font(.system(size: 16, weight: .semibold))
            Text("You've reviewed all due cards.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Button("Done") {
                flashcardsVM.endReview()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            Spacer()
        }
    }
}
