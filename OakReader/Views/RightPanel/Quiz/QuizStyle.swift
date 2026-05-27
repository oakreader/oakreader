import SwiftUI

/// Shared visual tokens for the inline quiz/flashcard UI — one place for the
/// per-type accent palette, typography, and metrics so the deck, cards, and
/// card-type views stay cohesive.
enum QuizStyle {
    // MARK: Per-type accent

    /// A distinct hue per card type, used for the badge, the top accent bar,
    /// progress dots, and revealed cloze answers.
    static func accent(for type: QuizType) -> Color {
        switch type {
        case .cloze:     return Color(red: 0.16, green: 0.68, blue: 0.63) // teal
        case .flashcard: return Color(red: 0.37, green: 0.44, blue: 0.93) // indigo
        case .choice:    return Color(red: 0.95, green: 0.61, blue: 0.20) // amber
        case .matching:  return Color(red: 0.91, green: 0.39, blue: 0.62) // pink
        case .ordering:  return Color(red: 0.58, green: 0.40, blue: 0.92) // violet
        case .occlusion: return Color(red: 0.27, green: 0.72, blue: 0.45) // green
        }
    }

    // MARK: Metrics

    static let deckCornerRadius: CGFloat = 16
    static let cardCornerRadius: CGFloat = 12
    static let cardAspectRatio: CGFloat = 16.0 / 9.0

    // MARK: Typography

    static let cardBody = Font.system(size: 15, weight: .regular)
    static let cardBodyEmphasis = Font.system(size: 15, weight: .semibold)
    static let typeLabel = Font.system(size: 11, weight: .semibold)
    static let hint = Font.system(size: 12, weight: .regular)
    static let counter = Font.system(size: 11, weight: .semibold, design: .rounded)

    // MARK: Motion

    /// Spring used for card-to-card navigation and stack shifts.
    static let cardSpring = Animation.spring(response: 0.38, dampingFraction: 0.82)
    /// Snappy spring for save / reveal "pop" feedback.
    static let pop = Animation.spring(response: 0.30, dampingFraction: 0.55)
}
