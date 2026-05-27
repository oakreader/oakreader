import SwiftUI

/// Router view that dispatches to the type-specific quiz view.
///
/// Two modes:
/// - **standalone** (default): self-contained card with a type badge, its own
///   surface, and an optional "Save to Deck" button — used for one-off inline
///   quizzes in a chat bubble.
/// - **chromeless** (`chromeless: true`): just the quiz body, no badge / surface
///   / save button — used inside `InlineDeckView`, which supplies the card
///   surface and badge itself so the content isn't boxed-in-a-box.
struct InlineQuizView: View {
    let content: QuizContent
    var onSaveToDeck: ((QuizContent) -> Bool)?
    var chromeless: Bool = false

    @State private var showSaved = false
    @State private var showSaveFailed = false

    var body: some View {
        if chromeless {
            quizBody
        } else {
            standalone
        }
    }

    private var standalone: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuizTypeBadge(type: content.quizType)
            quizBody
            if onSaveToDeck != nil {
                Divider()
                saveButton
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: QuizStyle.cardCornerRadius)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: QuizStyle.cardCornerRadius)
                .strokeBorder(QuizStyle.accent(for: content.quizType).opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var quizBody: some View {
        switch content {
        case .cloze(let c):     ClozeQuizView(content: c)
        case .choice(let c):    ChoiceQuizView(content: c)
        case .flashcard(let c): FlashcardQuizView(content: c)
        case .matching(let c):  MatchingQuizView(content: c)
        case .ordering(let c):  OrderingQuizView(content: c)
        case .occlusion(let c): OcclusionQuizView(content: c)
        }
    }

    @ViewBuilder
    private var saveButton: some View {
        Button {
            guard let onSaveToDeck else { return }
            if onSaveToDeck(content) {
                showSaved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSaved = false }
            } else {
                showSaveFailed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSaveFailed = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: saveIcon)
                    .font(.system(size: 11))
                Text(saveLabel)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(saveColor)
            .contentShape(Rectangle())
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
        return QuizStyle.accent(for: content.quizType)
    }
}

/// Small pill badge naming the card type, tinted with its accent hue.
struct QuizTypeBadge: View {
    let type: QuizType

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: type.systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(type.label)
                .font(QuizStyle.typeLabel)
        }
        .foregroundStyle(QuizStyle.accent(for: type))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(QuizStyle.accent(for: type).opacity(0.12))
        )
    }
}
