import SwiftUI

/// Renders a `QuizDeck` as a navigable carousel inline in the chat.
///
/// Features:
/// - Header with deck title and "Save All" button
/// - Single card displayed at a time via `InlineQuizView`
/// - Prev/next navigation with counter
/// - Individual "Save to Deck" per card via `InlineQuizView`'s existing button
struct InlineDeckView: View {
    let deck: QuizDeck
    var onSaveCard: ((QuizContent) -> Bool)?

    @State private var currentIndex = 0
    @State private var savedAll = false
    @State private var saveAllFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            deckHeader

            Divider()
                .padding(.horizontal, 12)

            // Card area
            if !deck.cards.isEmpty {
                cardArea
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            // Navigation bar
            if deck.cards.count > 1 {
                Divider()
                    .padding(.horizontal, 12)
                navigationBar
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Header

    private var deckHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.stack.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)

            if !deck.title.isEmpty {
                Text(deck.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }

            Text("\(deck.cards.count) cards")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            if onSaveCard != nil {
                saveAllButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var saveAllButton: some View {
        Button {
            guard let onSaveCard else { return }
            var allOK = true
            for card in deck.cards {
                if !onSaveCard(card) { allOK = false }
            }
            if allOK {
                savedAll = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { savedAll = false }
            } else {
                saveAllFailed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saveAllFailed = false }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: saveAllIcon)
                    .font(.system(size: 10))
                Text(saveAllLabel)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(saveAllColor)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: savedAll)
        .animation(.easeInOut(duration: 0.2), value: saveAllFailed)
    }

    private var saveAllIcon: String {
        if savedAll { return "checkmark" }
        if saveAllFailed { return "exclamationmark.triangle" }
        return "square.and.arrow.down.on.square"
    }

    private var saveAllLabel: String {
        if savedAll { return "All Saved" }
        if saveAllFailed { return "Save Failed" }
        return "Save All"
    }

    private var saveAllColor: Color {
        if savedAll { return .green }
        if saveAllFailed { return .red }
        return .accentColor
    }

    // MARK: - Card Area

    private var cardArea: some View {
        let clampedIndex = min(currentIndex, deck.cards.count - 1)
        let card = deck.cards[clampedIndex]

        return InlineQuizView(content: card, onSaveToDeck: onSaveCard)
            .id(clampedIndex)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(.easeInOut(duration: 0.25), value: currentIndex)
    }

    // MARK: - Navigation Bar

    private var navigationBar: some View {
        HStack(spacing: 10) {
            // Previous
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    currentIndex = max(0, currentIndex - 1)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(currentIndex > 0 ? .accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 24, height: 24)
                    .background(
                        currentIndex > 0
                            ? Color.accentColor.opacity(0.1)
                            : Color.secondary.opacity(0.05),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(currentIndex <= 0)

            // Counter
            Text("\(min(currentIndex + 1, deck.cards.count))/\(deck.cards.count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            // Next
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    currentIndex = min(deck.cards.count - 1, currentIndex + 1)
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        currentIndex < deck.cards.count - 1
                            ? .accentColor
                            : Color.secondary.opacity(0.3)
                    )
                    .frame(width: 24, height: 24)
                    .background(
                        currentIndex < deck.cards.count - 1
                            ? Color.accentColor.opacity(0.1)
                            : Color.secondary.opacity(0.05),
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(currentIndex >= deck.cards.count - 1)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
