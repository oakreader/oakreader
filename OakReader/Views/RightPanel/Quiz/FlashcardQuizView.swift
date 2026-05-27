import SwiftUI
import Textual

/// Flashcard with a front/back flip. Chromeless — sits directly on the deck's
/// card surface (no nested box), content centered, with a 3D flip on tap.
struct FlashcardQuizView: View {
    let content: QuizContent.FlashcardContent

    @State private var isFlipped = false
    private let accent = QuizStyle.accent(for: .flashcard)

    var body: some View {
        VStack(spacing: 12) {
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

            // Flip affordance
            HStack(spacing: 4) {
                Image(systemName: "hand.tap")
                Text(isFlipped ? "Tap to see question" : "Tap to reveal answer")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
            .transition(.opacity)
            .id(isFlipped)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                isFlipped.toggle()
            }
        }
    }

    private func face(tag: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tag)
                .font(.system(size: 9, weight: .heavy))
                .tracking(1.0)
                .foregroundStyle(accent)
            StructuredText(markdown: text)
                .font(.system(size: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
