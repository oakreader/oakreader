import SwiftUI

/// Router view that dispatches to the type-specific quiz view + "Save to Deck" button.
/// Used inline within chat bubbles for ephemeral quiz previews.
struct InlineQuizView: View {
    let content: QuizContent
    var onSaveToDeck: ((QuizContent) -> Bool)?

    @State private var showSaved = false
    @State private var showSaveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Type badge
            HStack(spacing: 4) {
                Image(systemName: content.quizType.systemImage)
                    .font(.system(size: 10))
                Text(content.quizType.label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.secondary)

            // Quiz content
            quizBody

            // Save button
            if onSaveToDeck != nil {
                Divider()
                saveButton
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var quizBody: some View {
        switch content {
        case .cloze(let c):
            ClozeQuizView(content: c)
        case .choice(let c):
            ChoiceQuizView(content: c)
        case .flashcard(let c):
            FlashcardQuizView(content: c)
        case .matching(let c):
            MatchingQuizView(content: c)
        case .ordering(let c):
            OrderingQuizView(content: c)
        case .occlusion:
            Text("Image occlusion not yet supported.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var saveButton: some View {
        Button {
            guard let onSaveToDeck else { return }
            if onSaveToDeck(content) {
                showSaved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showSaved = false
                }
            } else {
                showSaveFailed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    showSaveFailed = false
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: saveIcon)
                    .font(.system(size: 11))
                Text(saveLabel)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(saveColor)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: showSaved)
        .animation(.easeInOut(duration: 0.2), value: showSaveFailed)
    }

    private var saveIcon: String {
        if showSaved { return "checkmark" }
        if showSaveFailed { return "exclamationmark.triangle" }
        return "square.and.arrow.down"
    }

    private var saveLabel: String {
        if showSaved { return "Saved to Deck" }
        if showSaveFailed { return "Save Failed" }
        return "Save to Deck"
    }

    private var saveColor: Color {
        if showSaved { return .green }
        if showSaveFailed { return .red }
        return .accentColor
    }
}
