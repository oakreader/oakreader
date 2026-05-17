import SwiftUI
import Textual

/// Full-screen overlay for quiz card review sessions.
/// Covers the entire document window with an Anki-style minimal interface.
struct QuizCardReviewOverlay: View {
    let quizCardsVM: QuizCardsViewModel

    @State private var isRevealed = false
    @State private var userAnswer = ""
    @State private var selectedChoiceIndex: Int?
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        ZStack {
            // Full background
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            if quizCardsVM.isReviewSetup {
                reviewSetupView
            } else {
                reviewSessionView
            }
        }
        .onKeyPress(.escape) {
            quizCardsVM.endReview()
            return .handled
        }
    }

    // MARK: - Review Setup (Mode Selection)

    private var reviewSetupView: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Review Session")
                .font(.system(size: 24, weight: .semibold))

            Text("\(quizCardsVM.dueCards.count) cards due")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                ForEach(ReviewMode.allCases) { mode in
                    Button(action: { quizCardsVM.beginReview(mode: mode) }) {
                        VStack(spacing: 8) {
                            Image(systemName: mode.systemImage)
                                .font(.system(size: 24))
                            Text(mode.label)
                                .font(.system(size: 14, weight: .medium))
                            Text(mode.description)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 160, height: 100)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
            .padding(.top, 8)

            Button("Cancel") {
                quizCardsVM.cancelSetup()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.top, 8)

            Spacer()
        }
    }

    // MARK: - Review Session

    private var reviewSessionView: some View {
        VStack(spacing: 0) {
            // Header
            reviewHeader

            Divider()

            // Card content area
            if let card = quizCardsVM.currentReviewCard {
                ScrollView {
                    VStack(spacing: 16) {
                        cardContent(card)
                    }
                    .padding(OakStyle.Spacing.lg)
                    .frame(maxWidth: 640)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Bottom action area
                actionArea(card)
                    .padding(.horizontal, OakStyle.Spacing.lg)
                    .padding(.vertical, OakStyle.Spacing.md)
            } else {
                reviewCompleteView
            }
        }
        .onChange(of: quizCardsVM.currentReviewIndex) { _, _ in
            resetCardState()
        }
    }

    // MARK: - Header

    private var reviewHeader: some View {
        HStack {
            Button(action: { quizCardsVM.endReview() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.plain)
            .help("End review (Esc)")

            Spacer()

            Text("\(quizCardsVM.currentReviewIndex + 1)/\(quizCardsVM.dueCards.count)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            ProgressView(value: Double(quizCardsVM.currentReviewIndex), total: Double(quizCardsVM.dueCards.count))
                .frame(width: 120)
                .padding(.leading, 8)
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
                .font(.system(size: 16))
                .frame(maxWidth: .infinity, alignment: .leading)

            if isRevealed || quizCardsVM.currentEvaluationResult != nil {
                Divider()
                Text("Answer")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                StructuredText(markdown: c.back)
                    .font(.system(size: 16))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func clozeContent(_ c: QuizContent.ClozeContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if isRevealed || quizCardsVM.currentEvaluationResult != nil {
                StructuredText(markdown: revealCloze(c.text))
                    .font(.system(size: 16))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                StructuredText(markdown: hideCloze(c.text))
                    .font(.system(size: 16))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let hint = c.hint {
                    Text("Hint: \(hint)")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func choiceContent(_ c: QuizContent.ChoiceContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StructuredText(markdown: c.question)
                .font(.system(size: 16))
                .frame(maxWidth: .infinity, alignment: .leading)

            ForEach(Array(c.choices.enumerated()), id: \.offset) { idx, choice in
                Button(action: {
                    if selectedChoiceIndex == nil {
                        selectedChoiceIndex = idx
                        quizCardsVM.submitChoiceAnswer(selectedIndex: idx)
                    }
                }) {
                    HStack(spacing: 10) {
                        choiceIcon(for: idx, correctIndex: c.correctIndex)
                        Text(choice)
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(choiceBackground(for: idx, correctIndex: c.correctIndex))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(selectedChoiceIndex != nil)
            }

            if let result = quizCardsVM.currentEvaluationResult, let explanation = c.explanation {
                Divider()
                Text(explanation)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func matchingContent(_ c: QuizContent.MatchingContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Match the pairs:")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(Array(c.pairs.enumerated()), id: \.offset) { _, pair in
                HStack {
                    Text(pair.left)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isRevealed || quizCardsVM.currentEvaluationResult != nil {
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Text(pair.right)
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("???")
                            .font(.system(size: 14))
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
                .font(.system(size: 16))
                .frame(maxWidth: .infinity, alignment: .leading)

            if isRevealed || quizCardsVM.currentEvaluationResult != nil {
                ForEach(Array(c.items.enumerated()), id: \.offset) { idx, item in
                    HStack(spacing: 8) {
                        Text("\(idx + 1).")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Text(item)
                            .font(.system(size: 14))
                    }
                }
            } else {
                Text("Think about the correct order...")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Action Area

    @ViewBuilder
    private func actionArea(_ card: QuizCard) -> some View {
        if let result = quizCardsVM.currentEvaluationResult {
            // Show evaluation feedback + Next button
            evaluationFeedbackArea(result)
        } else if let error = quizCardsVM.evaluationError {
            // AI failed — show manual override
            manualOverrideArea(error: error)
        } else if quizCardsVM.isEvaluating {
            // Loading
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Evaluating...")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            // Input area based on mode and card type
            switch quizCardsVM.reviewMode {
            case .recognition:
                recognitionActionArea
            case .production:
                productionActionArea(card)
            }
        }
    }

    // MARK: Recognition Actions

    private var recognitionActionArea: some View {
        Group {
            if isRevealed {
                HStack(spacing: 16) {
                    Button(action: { quizCardsVM.submitRecognition(remembered: false) }) {
                        HStack(spacing: 4) {
                            Text("Forget")
                                .font(.system(size: 14, weight: .medium))
                            Text("(1)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .onKeyPress("1") {
                        quizCardsVM.submitRecognition(remembered: false)
                        return .handled
                    }

                    Button(action: { quizCardsVM.submitRecognition(remembered: true) }) {
                        HStack(spacing: 4) {
                            Text("Remember")
                                .font(.system(size: 14, weight: .medium))
                            Text("(2)")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)
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
                            .font(.system(size: 14, weight: .medium))
                        Text("(Space)")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .onKeyPress(.space) {
                    withAnimation(.easeInOut(duration: 0.2)) { isRevealed = true }
                    return .handled
                }
            }
        }
    }

    // MARK: Production Actions

    @ViewBuilder
    private func productionActionArea(_ card: QuizCard) -> some View {
        // Choice cards use tap-to-select, no text input needed
        if case .choice = card.content {
            if selectedChoiceIndex == nil {
                Text("Select an answer above")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: 8) {
                TextField("Type your answer...", text: $userAnswer)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        submitCurrentAnswer()
                    }

                VoiceInputButton(transcribedText: $userAnswer)

                Button(action: { submitCurrentAnswer() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .disabled(userAnswer.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Submit (Enter)")
            }
            .onAppear { isTextFieldFocused = true }
        }
    }

    // MARK: Evaluation Feedback

    private func evaluationFeedbackArea(_ result: EvaluationResult) -> some View {
        VStack(spacing: 12) {
            EvaluationFeedbackView(result: result)

            Button(action: { quizCardsVM.advanceAfterEvaluation() }) {
                HStack(spacing: 4) {
                    Text("Next")
                        .font(.system(size: 14, weight: .medium))
                    Text("(Enter)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .onKeyPress(.return) {
                quizCardsVM.advanceAfterEvaluation()
                return .handled
            }
        }
    }

    // MARK: Manual Override (AI failure)

    private func manualOverrideArea(error: String) -> some View {
        VStack(spacing: 12) {
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 16) {
                Button(action: { quizCardsVM.submitManualOverride(remembered: false) }) {
                    Text("Forget (1)")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button(action: { quizCardsVM.submitManualOverride(remembered: true) }) {
                    Text("Remember (2)")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.bordered)
                .tint(.green)
            }
        }
        .onKeyPress("1") {
            quizCardsVM.submitManualOverride(remembered: false)
            return .handled
        }
        .onKeyPress("2") {
            quizCardsVM.submitManualOverride(remembered: true)
            return .handled
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
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, 8)
            Spacer()
        }
    }

    // MARK: - Helpers

    private func resetCardState() {
        isRevealed = false
        userAnswer = ""
        selectedChoiceIndex = nil
        isTextFieldFocused = true
    }

    private func submitCurrentAnswer() {
        let trimmed = userAnswer.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task {
            await quizCardsVM.submitAnswer(trimmed)
        }
    }

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

    // MARK: Choice Helpers

    private func choiceIcon(for idx: Int, correctIndex: Int) -> some View {
        Group {
            if let selected = selectedChoiceIndex {
                if idx == correctIndex {
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
}
