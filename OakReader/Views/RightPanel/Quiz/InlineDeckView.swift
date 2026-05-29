import SwiftUI

/// Renders a `QuizDeck` as an elegant, navigable card carousel inline in the chat.
///
/// Design: a single elevated card surface (no boxes-in-boxes) with a faint
/// "stack" of cards peeking behind it, a per-type accent bar, dot-based
/// progress, and a compact footer. Navigation is direction-aware (cards slide
/// in from the side you're heading toward) and the whole thing is keyboard- and
/// swipe-navigable.
struct InlineDeckView: View {
    let deck: QuizDeck
    var onSaveCard: ((QuizContent) -> Bool)?
    /// Expanded (sheet) presentation — hides its own expand button.
    var embeddedInSheet: Bool = false

    @State private var currentIndex = 0
    @State private var navDirection = 1          // 1 = forward, -1 = back
    @State private var isFullScreen = false
    @State private var savedIndices: Set<Int> = []
    @State private var savePop = false
    @State private var saveAllFailed = false

    private var clampedIndex: Int {
        guard !deck.cards.isEmpty else { return 0 }
        return min(currentIndex, deck.cards.count - 1)
    }

    private var currentCard: QuizContent? {
        deck.cards.indices.contains(clampedIndex) ? deck.cards[clampedIndex] : nil
    }

    private var accent: Color {
        QuizStyle.accent(for: currentCard?.quizType ?? .flashcard)
    }

    private var showFooter: Bool {
        deck.cards.count > 1 || onSaveCard != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            cardStack
                .padding(.horizontal, 14)
                .padding(.bottom, showFooter ? 4 : 14)
            if showFooter { footerBar }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: QuizStyle.deckCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay(alignment: .top) {
            // Thin accent bar across the top, tinted by the current card type.
            UnevenRoundedRectangle(
                topLeadingRadius: QuizStyle.deckCornerRadius,
                topTrailingRadius: QuizStyle.deckCornerRadius,
                style: .continuous
            )
            .fill(accent)
            .frame(height: 3)
            .animation(.easeInOut(duration: 0.3), value: accent)
        }
        .overlay(
            RoundedRectangle(cornerRadius: QuizStyle.deckCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 14, x: 0, y: 5)
        .sheet(isPresented: $isFullScreen) {
            FullScreenDeckView(deck: deck, onSaveCard: onSaveCard)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let type = currentCard?.quizType {
                QuizTypeBadge(type: type)
                    .transition(.opacity)
                    .id(type)
            }

            if !deck.title.isEmpty {
                Text(deck.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if deck.cards.count > 1 { progressDots }

            if !embeddedInSheet {
                Button { isFullScreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Expand")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// One pip per card: current is a wide accent capsule, saved are filled
    /// accent dots, the rest faint. Tap a pip to jump to that card.
    private var progressDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<deck.cards.count, id: \.self) { idx in
                let isCurrent = idx == clampedIndex
                Capsule()
                    .fill(pipColor(idx))
                    .frame(width: isCurrent ? 14 : 6, height: 6)
                    .contentShape(Rectangle())
                    .onTapGesture { go(to: idx) }
            }
        }
        .animation(QuizStyle.cardSpring, value: clampedIndex)
        .animation(.easeInOut(duration: 0.2), value: savedIndices)
    }

    private func pipColor(_ idx: Int) -> Color {
        if idx == clampedIndex { return accent }
        if savedIndices.contains(idx) { return accent.opacity(0.55) }
        return Color.primary.opacity(0.15)
    }

    // MARK: - Card stack

    private var cardStack: some View {
        ZStack {
            // Faint stacked cards peeking behind — only when there's more ahead.
            if deck.cards.count > 1 {
                ForEach(1...2, id: \.self) { depth in
                    let hasMore = clampedIndex + depth < deck.cards.count
                    RoundedRectangle(cornerRadius: QuizStyle.cardCornerRadius, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: QuizStyle.cardCornerRadius, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
                        )
                        .scaleEffect(1 - CGFloat(depth) * 0.04)
                        .offset(y: CGFloat(depth) * 7)
                        .opacity(hasMore ? 0.6 : 0)
                        .animation(QuizStyle.cardSpring, value: clampedIndex)
                }
            }

            // Foreground card.
            if let card = currentCard {
                cardFace(card)
                    .id(clampedIndex)
                    .transition(cardTransition)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(QuizStyle.cardAspectRatio, contentMode: .fit)
        .animation(QuizStyle.cardSpring, value: clampedIndex)
        .gesture(swipeGesture)
    }

    private func cardFace(_ card: QuizContent) -> some View {
        // Content is centered within the 16:9 face; rare over-tall content is
        // clipped to the rounded card rather than blowing out the layout.
        InlineQuizView(content: card, onSaveToDeck: nil, chromeless: true)
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: QuizStyle.cardCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: QuizStyle.cardCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: QuizStyle.cardCornerRadius, style: .continuous))
    }

    /// Direction-aware slide + scale + fade.
    private var cardTransition: AnyTransition {
        let insertEdge: Edge = navDirection >= 0 ? .trailing : .leading
        let removeEdge: Edge = navDirection >= 0 ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: insertEdge)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.96)),
            removal: .move(edge: removeEdge).combined(with: .opacity)
        )
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                if value.translation.width < -40 { next() }
                else if value.translation.width > 40 { prev() }
            }
    }

    // MARK: - Navigation

    private func go(to index: Int) {
        let target = max(0, min(index, deck.cards.count - 1))
        guard target != clampedIndex else { return }
        navDirection = target > clampedIndex ? 1 : -1
        withAnimation(QuizStyle.cardSpring) { currentIndex = target }
    }

    private func next() { go(to: clampedIndex + 1) }
    private func prev() { go(to: clampedIndex - 1) }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            if deck.cards.count > 1 {
                navButton("chevron.left", enabled: clampedIndex > 0, action: prev)
                Text("\(clampedIndex + 1) / \(deck.cards.count)")
                    .font(QuizStyle.counter)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                navButton("chevron.right", enabled: clampedIndex < deck.cards.count - 1, action: next)
            }

            Spacer()

            if onSaveCard != nil {
                saveCurrentButton
                if deck.cards.count > 1 { saveAllButton }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func navButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(enabled ? accent : Color.secondary.opacity(0.3))
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(enabled ? accent.opacity(0.12) : Color.primary.opacity(0.04))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - Save

    private var isCurrentSaved: Bool { savedIndices.contains(clampedIndex) }

    private var saveCurrentButton: some View {
        Button {
            guard let onSaveCard, let card = currentCard, !isCurrentSaved else { return }
            if onSaveCard(card) {
                withAnimation(QuizStyle.pop) {
                    _ = savedIndices.insert(clampedIndex)
                    savePop = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { savePop = false }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isCurrentSaved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 11, weight: .medium))
                    .scaleEffect(savePop ? 1.3 : 1)
                Text(isCurrentSaved ? "Saved" : "Save")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isCurrentSaved ? accent : .secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCurrentSaved)
        .help("Save this card to your review deck")
    }

    private var saveAllButton: some View {
        Button {
            guard let onSaveCard else { return }
            var ok = true
            for (i, card) in deck.cards.enumerated() where !savedIndices.contains(i) {
                if onSaveCard(card) { savedIndices.insert(i) } else { ok = false }
            }
            if !ok {
                saveAllFailed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { saveAllFailed = false }
            }
        } label: {
            Text(saveAllFailed ? "Save Failed" : "Save all")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(saveAllFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: saveAllFailed)
        .animation(.easeInOut(duration: 0.2), value: savedIndices)
    }
}

// MARK: - Full-Screen Deck

/// Expanded presentation of a deck shown in a resizable sheet for focused
/// review. Reuses `InlineDeckView` (in `embeddedInSheet` mode) at a large frame.
private struct FullScreenDeckView: View {
    let deck: QuizDeck
    var onSaveCard: ((QuizContent) -> Bool)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill")
                    .foregroundStyle(Color.accentColor)
                Text(deck.title.isEmpty ? "Flashcards" : deck.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                InlineDeckView(deck: deck, onSaveCard: onSaveCard, embeddedInSheet: true)
                    .frame(maxWidth: 960)
                    .padding(32)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(
            minWidth: 820, idealWidth: 1120, maxWidth: .infinity,
            minHeight: 640, idealHeight: 860, maxHeight: .infinity
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
