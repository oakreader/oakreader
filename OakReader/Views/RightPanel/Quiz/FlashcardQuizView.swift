import SwiftUI

/// Flashcard with a front/back flip. Chromeless — sits directly on the deck's
/// card surface (no nested box). Content is vertically centered like a slide,
/// with the reveal affordance pinned near the bottom.
struct FlashcardQuizView: View {
    let content: QuizContent.FlashcardContent
    /// Slide-sized typography for the full-screen presentation.
    var large: Bool = false

    @State private var isFlipped = false

    var body: some View {
        VStack(spacing: large ? 22 : 14) {
            Spacer(minLength: 0)

            ZStack {
                face(tag: "QUESTION", text: content.front)
                    .opacity(isFlipped ? 0 : 1)
                    .rotation3DEffect(.degrees(isFlipped ? 180 : 0),
                                      axis: (x: 0, y: 1, z: 0), perspective: 0.4)
                face(tag: "ANSWER", text: content.back)
                    .opacity(isFlipped ? 1 : 0)
                    .rotation3DEffect(.degrees(isFlipped ? 0 : -180),
                                      axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            // Flip affordance
            HStack(spacing: 5) {
                Image(systemName: "hand.tap")
                Text(isFlipped ? "Tap to see question" : "Tap to reveal answer")
            }
            .font(.system(size: large ? 13 : 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .transition(.opacity)
            .id(isFlipped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                isFlipped.toggle()
            }
        }
    }

    private func face(tag: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: large ? 14 : 9) {
            Text(tag)
                .font(.system(size: large ? 11 : 9, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(.tertiary)
            CardMarkdown(text: text, fontSize: large ? 23 : 16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
