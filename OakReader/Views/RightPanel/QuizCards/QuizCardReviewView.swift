import SwiftUI
import Textual

/// Quiz card review view — Noji-inspired clean, minimal aesthetic.
struct QuizCardReviewView: View {
    let quizCardsVM: QuizCardsViewModel
    var onDismiss: (() -> Void)? = nil

    @AppStorage("quizCard_ratingButtonCount") private var ratingButtonCount: Int = 2
    @State private var isRevealed = false
    @State private var selectedChoiceIndex: Int?
    @FocusState private var isFocused: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        reviewSessionView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(reviewBackground)
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
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) { isRevealed = true }
                return .handled
            }
    }

    // MARK: - Theme

    private var reviewBackground: Color {
        colorScheme == .dark
            ? Color(nsColor: .windowBackgroundColor)
            : Color(white: 0.965)
    }

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(white: 0.11)
            : .white
    }

    private var cardBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    // MARK: - Review Session

    private var reviewSessionView: some View {
        VStack(spacing: 0) {
            if let card = quizCardsVM.currentReviewCard {
                // Progress bar
                progressBar

                Spacer(minLength: 24)

                // Card
                ScrollView {
                    cardContainer(card)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                }

                // Leech banner
                if let leechCard = quizCardsVM.leechDetectedCard {
                    leechBanner(leechCard)
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 32)
                        .padding(.top, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Spacer(minLength: 16)

                // Action buttons
                if quizCardsVM.leechDetectedCard == nil {
                    actionArea
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 28)
                }
            } else {
                reviewCompleteView
            }
        }
        .onChange(of: quizCardsVM.currentReviewIndex) { _, _ in
            withAnimation(.easeOut(duration: 0.15)) {
                isRevealed = false
                selectedChoiceIndex = nil
            }
        }
    }

    // MARK: - Progress

    private var progressBar: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Text("\(quizCardsVM.currentReviewIndex + 1) / \(quizCardsVM.dueCards.count)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 8)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.06))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.5))
                        .frame(width: geo.size.width * progress)
                        .animation(.spring(duration: 0.4), value: progress)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 24)
        }
    }

    private var progress: CGFloat {
        guard quizCardsVM.dueCards.count > 0 else { return 0 }
        return CGFloat(quizCardsVM.currentReviewIndex) / CGFloat(quizCardsVM.dueCards.count)
    }

    // MARK: - Card Container

    private func cardContainer(_ card: QuizCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardContent(card)
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.3 : 0.06), radius: 12, y: 4)
        .padding(.horizontal, 32)
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
        case .occlusion(let c):
            occlusionContent(c)
        }
    }

    private func flashcardContent(_ c: QuizContent.FlashcardContent) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StructuredText(markdown: c.front)
                .font(.system(size: 17))
                .frame(maxWidth: .infinity, alignment: .leading)

            if isRevealed {
                separator
                    .padding(.vertical, 20)

                Text("Answer")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .padding(.bottom, 8)

                StructuredText(markdown: c.back)
                    .font(.system(size: 17))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func clozeContent(_ c: QuizContent.ClozeContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if isRevealed {
                StructuredText(markdown: revealCloze(c.text))
                    .font(.system(size: 17))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                StructuredText(markdown: hideCloze(c.text))
                    .font(.system(size: 17))
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
        VStack(alignment: .leading, spacing: 14) {
            StructuredText(markdown: c.question)
                .font(.system(size: 17))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)

            ForEach(Array(c.choices.enumerated()), id: \.offset) { idx, choice in
                Button {
                    guard selectedChoiceIndex == nil else { return }
                    withAnimation(.spring(duration: 0.3)) {
                        selectedChoiceIndex = idx
                        isRevealed = true
                    }
                } label: {
                    HStack(spacing: 12) {
                        choiceIcon(for: idx, correctIndex: c.correctIndex)
                            .font(.system(size: 16))
                        Text(choice)
                            .font(.system(size: 15))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background(
                        choiceBackground(for: idx, correctIndex: c.correctIndex),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(choiceBorder(for: idx, correctIndex: c.correctIndex), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(selectedChoiceIndex != nil)
            }

            if isRevealed, let explanation = c.explanation {
                separator
                    .padding(.top, 4)
                Text(explanation)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private func choiceIcon(for idx: Int, correctIndex: Int) -> some View {
        if let selected = selectedChoiceIndex {
            if idx == correctIndex {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(hex: "199d00"))
            } else if idx == selected {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color(hex: "ff375b"))
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.quaternary)
            }
        } else {
            Image(systemName: "circle")
                .foregroundStyle(.quaternary)
        }
    }

    private func choiceBackground(for idx: Int, correctIndex: Int) -> Color {
        guard let selected = selectedChoiceIndex else {
            return Color.primary.opacity(0.03)
        }
        if idx == correctIndex {
            return Color(hex: "199d00").opacity(0.08)
        }
        if idx == selected {
            return Color(hex: "ff375b").opacity(0.08)
        }
        return Color.primary.opacity(0.03)
    }

    private func choiceBorder(for idx: Int, correctIndex: Int) -> Color {
        guard let selected = selectedChoiceIndex else {
            return Color.primary.opacity(0.06)
        }
        if idx == correctIndex {
            return Color(hex: "199d00").opacity(0.3)
        }
        if idx == selected {
            return Color(hex: "ff375b").opacity(0.3)
        }
        return Color.primary.opacity(0.06)
    }

    private func matchingContent(_ c: QuizContent.MatchingContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Match the pairs")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
                .padding(.bottom, 4)

            ForEach(Array(c.pairs.enumerated()), id: \.offset) { _, pair in
                HStack {
                    Text(pair.left)
                        .font(.system(size: 15))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isRevealed {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(pair.right)
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("???")
                            .font(.system(size: 15))
                            .foregroundStyle(.quaternary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func orderingContent(_ c: QuizContent.OrderingContent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StructuredText(markdown: c.prompt)
                .font(.system(size: 17))
                .frame(maxWidth: .infinity, alignment: .leading)

            if isRevealed {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(c.items.enumerated()), id: \.offset) { idx, item in
                        HStack(spacing: 10) {
                            Text("\(idx + 1)")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Color.primary.opacity(0.05), in: Circle())
                            Text(item)
                                .font(.system(size: 15))
                        }
                    }
                }
                .padding(.top, 4)
            } else {
                Text("Think about the correct order...")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Occlusion

    private func occlusionContent(_ c: QuizContent.OcclusionContent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = NSImage(contentsOfFile: c.imageURL) {
                let nsImage = image
                GeometryReader { geo in
                    let aspectRatio = nsImage.size.width / nsImage.size.height
                    let displayWidth = geo.size.width
                    let displayHeight = displayWidth / aspectRatio

                    ZStack(alignment: .topLeading) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: displayWidth, height: displayHeight)

                        ForEach(c.masks.indices, id: \.self) { idx in
                            let mask = c.masks[idx]
                            let x = (mask["x"] ?? 0) * displayWidth
                            let y = (mask["y"] ?? 0) * displayHeight
                            let w = (mask["w"] ?? 0) * displayWidth
                            let h = (mask["h"] ?? 0) * displayHeight

                            if !isRevealed {
                                occlusionMask(label: idx < c.labels.count ? c.labels[idx] : "", w: w, h: h)
                                    .offset(x: x, y: y)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .frame(width: displayWidth, height: displayHeight)
                }
                .aspectRatio(nsImage.size.width / nsImage.size.height, contentMode: .fit)
                .frame(maxHeight: 300)
            } else {
                Text("Image not found: \(c.imageURL)")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }

            if isRevealed && !c.labels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(c.labels.indices, id: \.self) { idx in
                        let label = c.labels[idx]
                        if !label.isEmpty {
                            HStack(spacing: 6) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, height: 18)
                                    .background(Color.primary.opacity(0.05), in: Circle())
                                Text(label)
                                    .font(.system(size: 14))
                            }
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func occlusionMask(label: String, w: CGFloat, h: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.blue.opacity(0.7))
            .frame(width: w, height: h)
            .overlay(
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(2)
            )
    }

    // MARK: - Leech Banner

    @AppStorage("quizCard_autoSuspendLeech") private var autoSuspendLeech: Bool = true

    private func leechBanner(_ card: QuizCard) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("This card is a leech (\(card.lapses) lapses)")
                        .font(.system(size: 13, weight: .semibold))
                    if autoSuspendLeech {
                        Text("Card has been auto-suspended")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button {
                    if !card.isSuspended {
                        quizCardsVM.toggleSuspend(card)
                    }
                    quizCardsVM.dismissLeechAlert()
                } label: {
                    Text("Suspend")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(card.isSuspended)

                Button {
                    quizCardsVM.regenerateCard(card)
                } label: {
                    Text("Regenerate")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    quizCardsVM.deleteCard(card)
                    quizCardsVM.dismissLeechAlert()
                } label: {
                    Text("Delete")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    quizCardsVM.dismissLeechAlert()
                } label: {
                    Text("Continue")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Separator

    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 1)
    }

    // MARK: - Action Area

    private var actionArea: some View {
        Group {
            if isRevealed {
                if ratingButtonCount == 4 {
                    fourButtonArea
                } else {
                    twoButtonArea
                }
            } else {
                showAnswerButton
            }
        }
    }

    private var showAnswerButton: some View {
        Button(action: { withAnimation(.spring(duration: 0.35, bounce: 0.15)) { isRevealed = true } }) {
            HStack(spacing: 6) {
                Text("Show Answer")
                    .font(.system(size: 14, weight: .semibold))
                Text("Space")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Rating Buttons

    private var twoButtonArea: some View {
        HStack(spacing: 10) {
            ratingButton(label: "Forget", key: "1", rating: .again, tint: Color(hex: "ff375b"))
            ratingButton(label: "Remember", key: "2", rating: .good, tint: Color(hex: "199d00"))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var fourButtonArea: some View {
        HStack(spacing: 8) {
            ratingButton(label: "Again", key: "1", rating: .again, tint: Color(hex: "ff375b"))
            ratingButton(label: "Hard", key: "2", rating: .hard, tint: Color(hex: "fb5825"))
            ratingButton(label: "Good", key: "3", rating: .good, tint: Color(hex: "199d00"))
            ratingButton(label: "Easy", key: "4", rating: .easy, tint: Color(hex: "009dff"))
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func ratingButton(label: String, key: String, rating: ReviewRating, tint: Color) -> some View {
        Button(action: { quizCardsVM.submitReview(rating: rating) }) {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                Text(key)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint.opacity(0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(tint.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onKeyPress(KeyEquivalent(key.first!)) {
            quizCardsVM.submitReview(rating: rating)
            return .handled
        }
    }

    // MARK: - Review Complete

    private var reviewCompleteView: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color(hex: "199d00").opacity(0.1))
                    .frame(width: 80, height: 80)
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(Color(hex: "199d00"))
            }

            VStack(spacing: 6) {
                Text("Review Complete")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("You've reviewed all \(quizCardsVM.dueCards.count) cards.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            Button {
                quizCardsVM.endReview()
                onDismiss?()
            } label: {
                Text("Done")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 28)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)

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
