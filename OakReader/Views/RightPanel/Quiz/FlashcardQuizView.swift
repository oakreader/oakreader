import SwiftUI
import Textual

/// Interactive flashcard with front/back flip animation.
struct FlashcardQuizView: View {
    let content: QuizContent.FlashcardContent

    @State private var isFlipped = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card
            ZStack {
                // Front
                cardFace(label: "Q", text: content.front)
                    .opacity(isFlipped ? 0 : 1)
                    .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))

                // Back
                cardFace(label: "A", text: content.back)
                    .opacity(isFlipped ? 1 : 0)
                    .rotation3DEffect(.degrees(isFlipped ? 0 : -180), axis: (x: 0, y: 1, z: 0))
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.35)) {
                    isFlipped.toggle()
                }
            }

            // Tap hint
            Text(isFlipped ? "Tap to see front" : "Tap to flip")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func cardFace(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            StructuredText(markdown: text)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}
