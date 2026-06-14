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
    /// Slide-sized typography for the full-screen deck presentation.
    var large: Bool = false

    var body: some View {
        if chromeless {
            quizBody
        } else {
            standalone
        }
    }

    private var standalone: some View {
        VStack(alignment: .leading, spacing: 12) {
            QuizTypeBadge(type: content.quizType)
            quizBody
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    @ViewBuilder
    private var quizBody: some View {
        switch content {
        case .cloze(let c):     ClozeQuizView(content: c)
        case .flashcard(let c): FlashcardQuizView(content: c, large: large)
        case .occlusion(let c): OcclusionQuizView(content: c)
        }
    }
}

/// Quiet, monochrome label naming the card type — matches the deck header so
/// inline quizzes and decks read as one family (no colored chrome).
struct QuizTypeBadge: View {
    let type: QuizType

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: type.systemImage)
                .font(.system(size: 10, weight: .medium))
            Text(type.label)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.secondary)
    }
}
