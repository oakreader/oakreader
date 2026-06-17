import SwiftUI

/// Flashcard with a front/back flip.
///
/// Two hosting modes:
/// - **`surface: true`** (deck): the whole card — surface included — flips as one
///   physical object, with a depth lift and a shadow that grows at the edge-on
///   midpoint. This is the "real" flashcard flip.
/// - **`surface: false`** (inline, host supplies the box): only the inner content
///   flips inside a frame the host already drew.
///
/// Either way a single animatable angle drives everything, so the visible face
/// swaps exactly at the 90° edge-on instant — the two faces never crossfade
/// through each other (no double-image ghost).
struct FlashcardQuizView: View {
    let content: QuizContent.FlashcardContent
    /// Slide-sized typography for the full-screen presentation.
    var large: Bool = false
    /// Draw a physical card surface and flip the whole card (depth + shadow).
    var surface: Bool = false
    var cornerRadius: CGFloat = 18
    var surfacePadding: CGFloat = 22
    /// A monotonic counter the host bumps to flip the card from the keyboard
    /// (Space / Return in the full-screen deck). Ignored at its initial value.
    var flipSignal: Int = 0
    /// Opens a tapped citation (`oak://cite/…`) at its source. When set, citation
    /// links navigate; either way, tapping one never flips the card.
    var onOpenCitation: ((String, CitationAnchor) -> Void)? = nil
    /// Jumps to the passage a card was generated from — `(verbatim quote, 1-based
    /// page?)`. Drives the quiet "Source · p. N" footnote on the answer side.
    var onJumpToSource: ((String, Int?) -> Void)? = nil

    /// 0 = front, 180 = back. The single source of truth for the flip; the
    /// visible side and every depth cue are derived from its live value.
    @State private var angle: Double = 0
    /// A citation tap and the card's tap-to-flip both fire from the same click,
    /// in an unspecified order. We defer the flip by one run-loop turn (so it
    /// runs after the click is fully processed) and skip it if a citation was
    /// opened within this window — the link always wins, ordering be damned.
    @State private var suppressFlipUntil: Date = .distantPast

    var body: some View {
        Flip3D(angle: angle,
               perspective: 0.4,
               lift: surface ? 0.04 : 0.02,
               shadowBase: surface ? (radius: large ? 24 : 12, y: large ? 8 : 4) : nil) { showBack in
            ZStack {
                side(tag: "QUESTION", text: content.front,
                     hint: large ? "Press space or tap to reveal answer" : "Tap to reveal answer")
                    .opacity(showBack ? 0 : 1)
                side(tag: "ANSWER", text: content.back,
                     hint: large ? "Press space or tap to flip back" : "Tap to see question",
                     showSource: true)
                    .opacity(showBack ? 1 : 0)
                    // The whole card is mirrored at 180°; counter-rotate the back
                    // side so its text reads the right way round.
                    .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
            .modifier(CardSurface(enabled: surface, radius: cornerRadius, padding: surfacePadding))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: requestFlip)
        .onChange(of: flipSignal) { _, _ in flip() }
    }

    /// Handles a link tapped inside the card. Marks the flip suppressed first so
    /// the deferred flip bails out, then navigates known citations.
    private func handleLink(_ url: URL) -> Bool {
        suppressFlipUntil = Date().addingTimeInterval(0.25)
        guard let (citeKey, anchor) = CitationAnchor.parse(from: url) else { return false }
        onOpenCitation?(citeKey, anchor)
        return true
    }

    private func requestFlip() {
        DispatchQueue.main.async {
            guard Date() >= suppressFlipUntil else { return }   // a citation won this click
            flip()
        }
    }

    /// Flip to the other face. Sturdy, near-overshoot-free — a card settling, not
    /// a spring toy.
    private func flip() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) {
            angle = angle < 90 ? 180 : 0
        }
    }

    private func side(tag: String, text: String, hint: String, showSource: Bool = false) -> some View {
        VStack(spacing: large ? 22 : 14) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: large ? 14 : 9) {
                Text(tag)
                    .font(.system(size: large ? 11 : 9, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(.tertiary)
                CardMarkdown(text: text, fontSize: large ? 23 : 16, onOpenURL: handleLink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showSource, let label = sourceLabel {
                    sourceFootnote(label)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Image(systemName: "hand.tap")
                Text(hint)
            }
            .font(.system(size: large ? 13 : 11, weight: .medium))
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The quiet "Source · p. N" label, when the card carries a citation we can
    /// actually act on (a page to jump to or a quote to find).
    private var sourceLabel: String? {
        guard onJumpToSource != nil else { return nil }
        if let page = content.sourcePage { return "Source · p. \(page)" }
        if (content.sourceQuote?.isEmpty == false) { return "Source" }
        return nil
    }

    private func sourceFootnote(_ label: String) -> some View {
        Button {
            onJumpToSource?(content.sourceQuote ?? "", content.sourcePage)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "text.viewfinder")
                Text(label)
            }
            .font(.system(size: large ? 12 : 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Jump to the source passage")
        .padding(.top, large ? 4 : 2)
    }
}

/// Drives a Y-axis flip from a single animatable angle (0…180°). Because the
/// view is `Animatable`, `body` re-runs at every interpolated frame, so the
/// face swap, the depth lift, and the shadow all stay locked to the *live*
/// angle rather than to a separate, possibly-drifting timeline.
private struct Flip3D<Content: View>: View, Animatable {
    var angle: Double
    var perspective: CGFloat
    /// Extra scale at the 90° midpoint — the card rising toward the viewer.
    var lift: CGFloat
    /// Resting shadow (radius, y). `nil` = no shadow (host owns the surface).
    var shadowBase: (radius: CGFloat, y: CGFloat)?
    @ViewBuilder var content: (Bool) -> Content

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        let showBack = angle >= 90
        // 0 when flat, 1 when edge-on; `abs` keeps spring overshoot well-behaved.
        let edge = abs(sin(angle * .pi / 180))
        content(showBack)
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: perspective)
            .scaleEffect(1 + lift * edge)
            .shadow(color: .black.opacity(shadowBase == nil ? 0 : 0.06 + 0.05 * edge),
                    radius: (shadowBase?.radius ?? 0) + (shadowBase == nil ? 0 : 8 * edge),
                    x: 0,
                    y: (shadowBase?.y ?? 0) + (shadowBase == nil ? 0 : 5 * edge))
    }
}

/// The card's rounded surface — extracted so the deck and the flip share one
/// definition and can't drift apart. A no-op when the host already drew a box.
private struct CardSurface: ViewModifier {
    let enabled: Bool
    let radius: CGFloat
    let padding: CGFloat

    func body(content: Content) -> some View {
        if enabled {
            content
                .padding(padding)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        } else {
            content
        }
    }
}
