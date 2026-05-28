import SwiftUI
import Textual

/// Quiz card review view — Noji-inspired clean, minimal aesthetic.
///
/// Split across files for readability (behaviour unchanged):
/// - this file — the session shell: progress, card container, completion, theme.
/// - `QuizCardReviewView+CardContent.swift` — the six per-type card renderers.
/// - `QuizCardReviewView+Actions.swift` — show-answer / rating bar / leech banner.
///
/// Members shared across those files are `internal` rather than `private`
/// because Swift's `private` is not visible to same-type extensions in other
/// files; file-local helpers stay `private`.
struct QuizCardReviewView: View {
    let quizCardsVM: QuizCardsViewModel
    var onDismiss: (() -> Void)?

    @AppStorage("quizCard_ratingButtonCount") var ratingButtonCount: Int = 2
    @AppStorage("quizCard_autoSuspendLeech") var autoSuspendLeech: Bool = true
    @State var isRevealed = false
    @State var selectedChoiceIndex: Int?
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
        guard !quizCardsVM.dueCards.isEmpty else { return 0 }
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
}
