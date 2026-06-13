import SwiftUI

/// Router view that dispatches to the type-specific quiz view.
///
/// Two modes:
/// - **standalone** (default): self-contained card with a type badge and its own
///   surface — used for one-off inline quizzes in a chat bubble.
/// - **chromeless** (`chromeless: true`): just the quiz body, no badge / surface
///   — used inside `InlineDeckView`, which supplies the card surface and badge
///   itself so the content isn't boxed-in-a-box.
struct InlineQuizView: View {
    let content: QuizContent
    var chromeless: Bool = false

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
        case .flashcard(let c): FlashcardQuizView(content: c)
        case .occlusion(let c): OcclusionQuizView(content: c)
        }
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
