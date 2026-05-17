import SwiftUI

/// Stateless, read-only renderer for any `QuizContent` case.
/// Used by both `PendingQuizView` (document panel) and `CollectionQuizPendingView` (library panel).
struct QuizCardPreviewContent: View {
    let content: QuizContent

    var body: some View {
        switch content {
        case .flashcard(let c):
            flashcardPreview(c)
        case .cloze(let c):
            clozePreview(c)
        case .choice(let c):
            choicePreview(c)
        case .matching(let c):
            matchingPreview(c)
        case .ordering(let c):
            orderingPreview(c)
        case .occlusion:
            Text("Image occlusion card")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Card Types

    private func flashcardPreview(_ c: QuizContent.FlashcardContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Front")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Text(c.front)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Back")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Text(c.back)
                    .font(.system(size: 15))
                    .textSelection(.enabled)
            }
        }
    }

    private func clozePreview(_ c: QuizContent.ClozeContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(maskedClozeText(c.text))
                .font(.system(size: 15))
                .textSelection(.enabled)

            if let hint = c.hint, !hint.isEmpty {
                Text("Hint: \(hint)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
    }

    private func choicePreview(_ c: QuizContent.ChoiceContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(c.question)
                .font(.system(size: 15, weight: .medium))
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(c.choices.enumerated()), id: \.offset) { index, choice in
                    HStack(spacing: 8) {
                        Image(systemName: index == c.correctIndex ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13))
                            .foregroundStyle(index == c.correctIndex ? .green : .secondary)
                        Text(choice)
                            .font(.system(size: 14))
                    }
                }
            }
        }
    }

    private func matchingPreview(_ c: QuizContent.MatchingContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Match the pairs:")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(Array(c.pairs.enumerated()), id: \.offset) { _, pair in
                HStack(spacing: 12) {
                    Text(pair.left)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(pair.right)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func orderingPreview(_ c: QuizContent.OrderingContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(c.prompt)
                .font(.system(size: 15, weight: .medium))
                .textSelection(.enabled)

            ForEach(Array(c.items.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 8) {
                    Text("\(index + 1).")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    Text(item)
                        .font(.system(size: 14))
                }
            }
        }
    }

    // MARK: - Helpers

    /// Replaces {{c1::answer}} patterns with [___] for display
    private func maskedClozeText(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\{\\{c\\d+::(.*?)\\}\\}",
            with: "[___]",
            options: .regularExpression
        )
    }
}
