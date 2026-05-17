import Foundation
import FSRS

/// Thin wrapper around the `swift-fsrs` library (FSRS-5/6).
///
/// Converts between our domain models (`QuizCard`, `ReviewRating`) and
/// the library's types (`Card`, `Rating`), then delegates all scheduling
/// math to the battle-tested upstream implementation.
///
/// This mirrors how Anki integrates FSRS:
/// 1. Convert the stored card state → FSRS `Card`
/// 2. Call `fsrs.next(card:now:grade:)` to get the new card + review log
/// 3. Persist the updated FSRS fields back to the database
enum QuizScheduler {

    // MARK: - Shared FSRS Instance

    /// Lazily create the FSRS scheduler with current user parameters.
    /// Uses FSRS-5 defaults (19-weight vector) with short-term scheduling enabled,
    /// matching Anki's default FSRS behavior.
    static func makeScheduler() -> FSRS {
        let params = FSRSParameters(
            requestRetention: userRequestedRetention,
            maximumInterval: userMaximumInterval,
            enableFuzz: true,    // Anki enables fuzz to spread reviews
            enableShortTerm: true
        )
        return FSRS(parameters: params)
    }

    // MARK: - User Preferences

    /// Read target retention from UserDefaults (set in QuizCardSettingsView).
    private static var userRequestedRetention: Double {
        let value = UserDefaults.standard.double(forKey: "quizCard_targetRetention")
        return value > 0 ? value : 0.9
    }

    /// Read maximum interval from UserDefaults.
    private static var userMaximumInterval: Double {
        let value = UserDefaults.standard.integer(forKey: "quizCard_maxInterval")
        return value > 0 ? Double(value) : 36500.0
    }

    // MARK: - Scheduling Result (view-friendly)

    /// Result of scheduling a review, extracted from FSRS library types.
    struct SchedulingResult {
        var state: QuizCardState
        var dueAt: Date
        var stability: Double
        var difficulty: Double
        var scheduledDays: Int
        var elapsedDays: Int
        var reps: Int
        var lapses: Int
    }

    // MARK: - Public API

    /// Schedule the next review for a card given a rating.
    /// Returns a view-friendly SchedulingResult.
    static func schedule(
        card: QuizCard,
        rating: ReviewRating,
        now: Date = Date()
    ) -> SchedulingResult? {
        let fsrs = makeScheduler()
        let fsrsCard = toFSRSCard(card)
        let fsrsRating = toFSRSRating(rating)

        guard let result = try? fsrs.next(card: fsrsCard, now: now, grade: fsrsRating) else {
            return nil
        }

        let newCard = result.card
        return SchedulingResult(
            state: fromFSRSState(newCard.state),
            dueAt: newCard.due,
            stability: newCard.stability,
            difficulty: newCard.difficulty,
            scheduledDays: Int(newCard.scheduledDays),
            elapsedDays: Int(newCard.elapsedDays),
            reps: newCard.reps,
            lapses: newCard.lapses
        )
    }

    /// Get the current retrievability of a card (0.0–1.0).
    static func retrievability(card: QuizCard, now: Date = Date()) -> Double {
        let fsrs = makeScheduler()
        let fsrsCard = toFSRSCard(card)
        return fsrs.getRetrievability(card: fsrsCard, now: now).number
    }

    // MARK: - Conversion: QuizCard → FSRS Card

    static func toFSRSCard(_ card: QuizCard) -> Card {
        Card(
            due: card.dueAt,
            stability: card.stability,
            difficulty: card.difficulty,
            elapsedDays: Double(card.elapsedDays),
            scheduledDays: Double(card.scheduledDays),
            reps: card.reps,
            lapses: card.lapses,
            state: toFSRSState(card.state),
            lastReview: card.lastReviewAt
        )
    }

    // MARK: - Conversion: FSRS types ↔ our domain types

    static func toFSRSState(_ state: QuizCardState) -> CardState {
        switch state {
        case .new: return .new
        case .learning: return .learning
        case .review: return .review
        case .relearning: return .relearning
        }
    }

    static func fromFSRSState(_ state: CardState) -> QuizCardState {
        switch state {
        case .new: return .new
        case .learning: return .learning
        case .review: return .review
        case .relearning: return .relearning
        }
    }

    static func toFSRSRating(_ rating: ReviewRating) -> Rating {
        switch rating {
        case .again: return .again
        case .hard: return .hard
        case .good: return .good
        case .easy: return .easy
        }
    }
}
