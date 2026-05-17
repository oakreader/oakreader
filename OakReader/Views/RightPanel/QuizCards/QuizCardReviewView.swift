import SwiftUI
import Textual

/// Quiz card review tab with an Anki-style minimal interface.
struct QuizCardReviewView: View {
    let quizCardsVM: QuizCardsViewModel
    var onDismiss: (() -> Void)? = nil

    @State private var isRevealed = false
    @State private var selectedChoiceIndex: Int?
    @FocusState private var isFocused: Bool

    var body: some View {
        reviewSessionView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear { isFocused = true }
            .onKeyPress(.escape) {
                quizCardsVM.endReview()
                onDismiss?()
                return .handled
            }
            .onKeyPress(.space) {
                guard !isRevealed else { return .ignored }
                withAnimation(.easeInOut(duration: 0.2)) { isRevealed = true }
                return .handled
            }
    }

    // MARK: - Review Session

    private var reviewSessionView: some View {
        VStack(spacing: 0) {
            reviewHeader

            if let card = quizCardsVM.currentReviewCard {
                ScrollView {
                    VStack(spacing: 16) {
                        cardContent(card)
                    }
                    .padding(OakStyle.Spacing.lg)
                    .frame(maxWidth: 640)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                recognitionActionArea
                    .frame(maxWidth: 640)
                    .padding(.horizontal, OakStyle.Spacing.lg)
                    .padding(.vertical, OakStyle.Spacing.md)
            } else {
                reviewCompleteView
            }
        }
        .onChange(of: quizCardsVM.currentReviewIndex) { _, _ in
            isRevealed = false
            selectedChoiceIndex = nil
        }
    }

    // MARK: - Header

    private var reviewHeader: some View {
        HStack {
            Spacer()
            Text("\(quizCardsVM.currentReviewIndex + 1)/\(quizCardsVM.dueCards.count)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, OakStyle.Spacing.md)
        .padding(.vertical, OakStyle.Spacing.sm)
    }

    // MARK: - Card Content

    @ViewBuilder
    private func cardContent(_ card: QuizCard) -> some View {
        switch card.content {
        case .flashcard(let c):
            flashcardContent(c)
        case .cloze(let c):
            clozeContent(c)
        case .choice(let c):
            choiceContent(c)
        case .matching(let c):
            matchingContent(c)
        case .ordering(let c):
            orderingContent(c)
        case .occlusion:
            Text("Image occlusion not yet supported.")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
        }
    }

    private func flashcardContent(_ c: QuizContent.FlashcardContent) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            StructuredText(markdown: c.front)
                .font(.system(size: 18))
                .frame(maxWidth: .infinity, alignment: .leading)

            if isRevealed {
                Divider()
                Text("Answer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                StructuredText(markdown: c.back)
                    .font(.system(size: 18))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func clozeContent(_ c: QuizContent.ClozeContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if isRevealed {
                StructuredText(markdown: revealCloze(c.text))
                    .font(.system(size: 18))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                StructuredText(markdown: hideCloze(c.text))
                    .font(.system(size: 18))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let hint = c.hint {
                    Text("Hint: \(hint)")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func choiceContent(_ c: QuizContent.ChoiceContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StructuredText(markdown: c.question)
                .font(.system(size: 18))
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(Array(c.choices.enumerated()), id: \.offset) { idx, choice in
                Button {
                    guard selectedChoiceIndex == nil else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedChoiceIndex = idx
                        isRevealed = true
                    }
                } label: {
                    HStack(spacing: 10) {
                        if let selected = selectedChoiceIndex {
                            if idx == c.correctIndex {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if idx == selected {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                        }
                        Text(choice)
                            .font(.system(size: 15))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(choiceBackground(for: idx, correctIndex: c.correctIndex))
                    )
                }
                .buttonStyle(.plain)
                .disabled(selectedChoiceIndex != nil)
            }

            if isRevealed, let explanation = c.explanation {
                Divider()
                Text(explanation)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func choiceBackground(for idx: Int, correctIndex: Int) -> Color {
        guard let selected = selectedChoiceIndex else {
            return Color.primary.opacity(0.04)
        }
        if idx == correctIndex {
            return Color.green.opacity(0.1)
        }
        if idx == selected {
            return Color.red.opacity(0.1)
        }
        return Color.primary.opacity(0.04)
    }

    private func matchingContent(_ c: QuizContent.MatchingContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Match the pairs:")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(Array(c.pairs.enumerated()), id: \.offset) { _, pair in
                HStack {
                    Text(pair.left)
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isRevealed {
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Text(pair.right)
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("???")
                            .font(.system(size: 15))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func orderingContent(_ c: QuizContent.OrderingContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            StructuredText(markdown: c.prompt)
                .font(.system(size: 18))
                .frame(maxWidth: .infinity, alignment: .leading)

            if isRevealed {
                ForEach(Array(c.items.enumerated()), id: \.offset) { idx, item in
                    HStack(spacing: 8) {
                        Text("\(idx + 1).")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Text(item)
                            .font(.system(size: 15))
                    }
                }
            } else {
                Text("Think about the correct order...")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Action Area

    private var recognitionActionArea: some View {
        Group {
            if isRevealed {
                HStack(spacing: 12) {
                    Button(action: { quizCardsVM.submitRecognition(remembered: false) }) {
                        HStack(spacing: 4) {
                            Text("Forget")
                                .font(.system(size: 13, weight: .medium))
                            Text("(1)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .onKeyPress("1") {
                        quizCardsVM.submitRecognition(remembered: false)
                        return .handled
                    }

                    Button(action: { quizCardsVM.submitRecognition(remembered: true) }) {
                        HStack(spacing: 4) {
                            Text("Remember")
                                .font(.system(size: 13, weight: .medium))
                            Text("(2)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .onKeyPress("2") {
                        quizCardsVM.submitRecognition(remembered: true)
                        return .handled
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isRevealed = true } }) {
                    HStack(spacing: 4) {
                        Text("Show Answer")
                            .font(.system(size: 13, weight: .medium))
                        Text("(Space)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Review Complete

    private var reviewCompleteView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Review Complete")
                .font(.system(size: 20, weight: .semibold))
            Text("You've reviewed all \(quizCardsVM.dueCards.count) cards.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Button("Done") {
                quizCardsVM.endReview()
                onDismiss?()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Helpers

    private func hideCloze(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\{\{c\d+::([^}]*?)(?:::[^}]*)?\}\}"#,
            with: "`___`",
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
}
