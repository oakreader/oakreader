import SwiftUI

/// Renders a `QuizDeck` as a clean, navigable card carousel.
///
/// Design (Dia-inspired): a *single* card surface — no boxes-in-boxes, no
/// colored chrome. A quiet title row floats above the card, a centered pager
/// floats below it, both on the panel background. In `embeddedInSheet` mode the
/// card fills the available height like a presentation slide.
struct InlineDeckView: View {
    let deck: QuizDeck
    var onSaveCard: ((QuizContent) -> Bool)?
    /// Opens a tapped citation at its source (forwarded to each card body).
    var onOpenCitation: ((String, CitationAnchor) -> Void)? = nil
    /// Full-screen "slide" presentation: the card fills the height, type is
    /// larger, and the view's own expand button is hidden.
    var embeddedInSheet: Bool = false
    /// When set, the expand button routes through this closure (e.g. the Studio
    /// full-window overlay) instead of the built-in centered sheet.
    var onExpand: (() -> Void)? = nil

    @State private var currentIndex = 0
    @State private var navDirection = 1          // 1 = forward, -1 = back
    @State private var isFullScreen = false
    @State private var savedIndices: Set<Int> = []
    @State private var savePop = false
    @State private var saveAllFailed = false

    private var isSlide: Bool { embeddedInSheet }
    private var cardRadius: CGFloat { isSlide ? 22 : 18 }

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
        VStack(alignment: .leading, spacing: isSlide ? 16 : 9) {
            header
            cardStack
            if showFooter { footerBar }
        }
        .frame(maxWidth: .infinity, maxHeight: isSlide ? .infinity : nil, alignment: .top)
        .sheet(isPresented: $isFullScreen) {
            FullScreenDeckView(deck: deck, onSaveCard: onSaveCard, onOpenCitation: onOpenCitation)
        }
    }

    // MARK: - Header (quiet, on panel background)

    private var header: some View {
        HStack(spacing: 8) {
            if let type = currentCard?.quizType {
                HStack(spacing: 5) {
                    Image(systemName: type.systemImage)
                        .font(.system(size: isSlide ? 12 : 10, weight: .medium))
                    Text(type.label)
                        .font(.system(size: isSlide ? 13 : 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .transition(.opacity)
                .id(type)
            }

            if !deck.title.isEmpty {
                Text(deck.title)
                    .font(.system(size: isSlide ? 13 : 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !embeddedInSheet {
                Button { if let onExpand { onExpand() } else { isFullScreen = true } } label: {
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
        .padding(.horizontal, 2)
    }

    // MARK: - Card stack (the single surface)

    private var cardStack: some View {
        sizedStack
            .frame(maxWidth: .infinity)
            .animation(QuizStyle.cardSpring, value: clampedIndex)
            .gesture(swipeGesture)
    }

    @ViewBuilder
    private var sizedStack: some View {
        if isSlide {
            stackContent.frame(maxHeight: .infinity)
        } else {
            stackContent.aspectRatio(QuizStyle.cardAspectRatio, contentMode: .fit)
        }
    }

    private var stackContent: some View {
        ZStack {
            // Faint stacked cards peeking behind, hinting there's more ahead.
            if deck.cards.count > 1 && !isSlide {
                ForEach(1...2, id: \.self) { depth in
                    let hasMore = clampedIndex + depth < deck.cards.count
                    RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
                        )
                        .scaleEffect(1 - CGFloat(depth) * 0.035)
                        .offset(y: CGFloat(depth) * 7)
                        .opacity(hasMore ? 0.5 : 0)
                        .animation(QuizStyle.cardSpring, value: clampedIndex)
                }
            }

            if let card = currentCard {
                currentCardView(card)
                    .id(clampedIndex)
                    .transition(cardTransition)
            }
        }
    }

    /// Flashcards flip the whole card surface as one physical object, so they
    /// draw their own surface; other quiz types sit on the shared static surface.
    @ViewBuilder
    private func currentCardView(_ card: QuizContent) -> some View {
        if case .flashcard(let flashcard) = card {
            FlashcardQuizView(content: flashcard,
                              large: isSlide,
                              surface: true,
                              cornerRadius: cardRadius,
                              surfacePadding: isSlide ? 40 : 22,
                              onOpenCitation: onOpenCitation)
        } else {
            cardFace(card)
        }
    }

    private func cardFace(_ card: QuizContent) -> some View {
        InlineQuizView(content: card, chromeless: true, large: isSlide, onOpenCitation: onOpenCitation)
            .padding(isSlide ? 40 : 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.06), radius: isSlide ? 24 : 12, x: 0, y: isSlide ? 8 : 4)
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

    // MARK: - Footer (centered pager, on panel background)

    private var footerBar: some View {
        ZStack {
            if deck.cards.count > 1 {
                HStack(spacing: 14) {
                    navButton("chevron.left", enabled: clampedIndex > 0, action: prev)
                    Text("\(clampedIndex + 1) / \(deck.cards.count)")
                        .font(QuizStyle.counter)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .frame(minWidth: 46)
                    navButton("chevron.right", enabled: clampedIndex < deck.cards.count - 1, action: next)
                }
            }

            if onSaveCard != nil {
                HStack(spacing: 12) {
                    Spacer()
                    saveCurrentButton
                    if deck.cards.count > 1 { saveAllButton }
                }
            }
        }
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private func navButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.3))
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(Color.primary.opacity(enabled ? 0.06 : 0.03))
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

// MARK: - Full-Screen Deck (presentation "slide")

/// Expanded presentation of a deck shown in a resizable sheet for focused
/// review. The card fills the sheet like a slide — no stranded whitespace.
private struct FullScreenDeckView: View {
    let deck: QuizDeck
    var onSaveCard: ((QuizContent) -> Bool)?
    var onOpenCitation: ((String, CitationAnchor) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(deck.title.isEmpty ? "Flashcards" : deck.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().opacity(0.5)

            InlineDeckView(deck: deck, onSaveCard: onSaveCard, onOpenCitation: onOpenCitation, embeddedInSheet: true)
                .frame(maxWidth: 1040, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(
            minWidth: 760, idealWidth: 1080, maxWidth: .infinity,
            minHeight: 600, idealHeight: 780, maxHeight: .infinity
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
