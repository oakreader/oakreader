import Foundation

/// Lightweight FSRS-5 (Free Spaced Repetition Scheduler) implementation.
///
/// Reference: https://github.com/open-spaced-repetition/fsrs4anki/wiki/The-Algorithm
///
/// The algorithm computes new stability (S) and difficulty (D) values after each review,
/// then schedules the next review date based on desired retention and the forgetting curve.
enum QuizScheduler {

    // MARK: - Parameters (FSRS-5 defaults)

    struct Parameters {
        var requestedRetention: Double = 0.9
        var maximumInterval: Int = 36500  // ~100 years
        var w: [Double] = [
            0.4072, 1.1829, 3.1262, 15.4722,   // w0–w3: initial stability for Again/Hard/Good/Easy
            7.2102, 0.5316, 1.0651,              // w4–w6: difficulty
            0.0589, 1.5947, 0.2753, 1.0278,      // w7–w10: stability after success
            1.9395, 0.1100, 0.5468, 2.0510,       // w11–w14: stability after failure
            0.1602, 3.0590, 0.3240, 0.3975,       // w15–w18: short-term
        ]
    }

    /// Result of scheduling a review.
    struct SchedulingResult {
        var state: CardState
        var stability: Double
        var difficulty: Double
        var dueAt: Date
        var scheduledDays: Int
        var elapsedDays: Int
    }

    // MARK: - Public API

    /// Schedule the next review for a card given a rating.
    static func schedule(
        card: QuizCard,
        rating: ReviewRating,
        now: Date = Date(),
        params: Parameters = Parameters()
    ) -> SchedulingResult {
        let elapsedDays: Int
        if let lastReview = card.lastReviewAt {
            elapsedDays = max(0, Int(now.timeIntervalSince(lastReview) / 86400))
        } else {
            elapsedDays = 0
        }

        switch card.state {
        case .new:
            return scheduleNew(rating: rating, now: now, params: params)
        case .learning, .relearning:
            return scheduleShortTerm(
                card: card, rating: rating, elapsedDays: elapsedDays,
                now: now, params: params
            )
        case .review:
            return scheduleLongTerm(
                card: card, rating: rating, elapsedDays: elapsedDays,
                now: now, params: params
            )
        }
    }

    // MARK: - New Card

    private static func scheduleNew(
        rating: ReviewRating,
        now: Date,
        params: Parameters
    ) -> SchedulingResult {
        let w = params.w
        // Initial stability from w0–w3
        let s = w[rating.rawValue - 1]
        // Initial difficulty
        let d = clamp(w[4] - exp(w[5] * Double(rating.rawValue - 1)) + 1, 1, 10)

        switch rating {
        case .again:
            return SchedulingResult(
                state: .learning, stability: s, difficulty: d,
                dueAt: now.addingTimeInterval(60), scheduledDays: 0, elapsedDays: 0
            )
        case .hard:
            return SchedulingResult(
                state: .learning, stability: s, difficulty: d,
                dueAt: now.addingTimeInterval(5 * 60), scheduledDays: 0, elapsedDays: 0
            )
        case .good:
            return SchedulingResult(
                state: .learning, stability: s, difficulty: d,
                dueAt: now.addingTimeInterval(10 * 60), scheduledDays: 0, elapsedDays: 0
            )
        case .easy:
            let interval = nextInterval(stability: s, params: params)
            return SchedulingResult(
                state: .review, stability: s, difficulty: d,
                dueAt: now.addingTimeInterval(Double(interval) * 86400),
                scheduledDays: interval, elapsedDays: 0
            )
        }
    }

    // MARK: - Short-Term (Learning / Relearning)

    private static func scheduleShortTerm(
        card: QuizCard,
        rating: ReviewRating,
        elapsedDays: Int,
        now: Date,
        params: Parameters
    ) -> SchedulingResult {
        let w = params.w
        let s = card.stability
        let d = card.difficulty

        // Update difficulty
        let newD = nextDifficulty(d: d, rating: rating, params: params)

        switch rating {
        case .again:
            let newS = w[15..<w.count].count > 2
                ? s * exp(w[17] * (Double(rating.rawValue) - 3 + w[18]))
                : max(s * 0.5, w[0])
            return SchedulingResult(
                state: card.state == .learning ? .learning : .relearning,
                stability: max(newS, 0.01), difficulty: newD,
                dueAt: now.addingTimeInterval(60), scheduledDays: 0, elapsedDays: elapsedDays
            )
        case .hard:
            let newS = w[15..<w.count].count > 2
                ? s * exp(w[17] * (Double(rating.rawValue) - 3 + w[18]))
                : s
            return SchedulingResult(
                state: card.state == .learning ? .learning : .relearning,
                stability: max(newS, 0.01), difficulty: newD,
                dueAt: now.addingTimeInterval(5 * 60), scheduledDays: 0, elapsedDays: elapsedDays
            )
        case .good:
            let newS = w.count > 17
                ? s * exp(w[17] * (Double(rating.rawValue) - 3 + w[18]))
                : s
            let interval = nextInterval(stability: max(newS, 0.01), params: params)
            return SchedulingResult(
                state: .review, stability: max(newS, 0.01), difficulty: newD,
                dueAt: now.addingTimeInterval(Double(interval) * 86400),
                scheduledDays: interval, elapsedDays: elapsedDays
            )
        case .easy:
            let newS = w.count > 17
                ? s * exp(w[17] * (Double(rating.rawValue) - 3 + w[18]))
                : s * 1.5
            let interval = nextInterval(stability: max(newS, 0.01), params: params)
            return SchedulingResult(
                state: .review, stability: max(newS, 0.01), difficulty: newD,
                dueAt: now.addingTimeInterval(Double(interval) * 86400),
                scheduledDays: interval, elapsedDays: elapsedDays
            )
        }
    }

    // MARK: - Long-Term (Review)

    private static func scheduleLongTerm(
        card: QuizCard,
        rating: ReviewRating,
        elapsedDays: Int,
        now: Date,
        params: Parameters
    ) -> SchedulingResult {
        let w = params.w
        let s = card.stability
        let d = card.difficulty

        let newD = nextDifficulty(d: d, rating: rating, params: params)
        let retrievability = forgettingCurve(elapsedDays: elapsedDays, stability: s)

        switch rating {
        case .again:
            // Stability after forgetting
            let newS = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp((1 - retrievability) * w[14])
            let lapses = card.lapses + 1
            return SchedulingResult(
                state: .relearning, stability: max(newS, 0.01), difficulty: newD,
                dueAt: now.addingTimeInterval(60), scheduledDays: 0, elapsedDays: elapsedDays
            )
        case .hard:
            let newS = s * (1 + exp(w[7]) * (11 - d) * pow(s, -w[8]) * (exp((1 - retrievability) * w[9]) - 1)) * w[15]
            let interval = nextInterval(stability: max(newS, 0.01), params: params)
            return SchedulingResult(
                state: .review, stability: max(newS, 0.01), difficulty: newD,
                dueAt: now.addingTimeInterval(Double(interval) * 86400),
                scheduledDays: interval, elapsedDays: elapsedDays
            )
        case .good:
            let newS = s * (1 + exp(w[7]) * (11 - d) * pow(s, -w[8]) * (exp((1 - retrievability) * w[9]) - 1))
            let interval = nextInterval(stability: max(newS, 0.01), params: params)
            return SchedulingResult(
                state: .review, stability: max(newS, 0.01), difficulty: newD,
                dueAt: now.addingTimeInterval(Double(interval) * 86400),
                scheduledDays: interval, elapsedDays: elapsedDays
            )
        case .easy:
            let newS = s * (1 + exp(w[7]) * (11 - d) * pow(s, -w[8]) * (exp((1 - retrievability) * w[9]) - 1)) * w[16]
            let interval = nextInterval(stability: max(newS, 0.01), params: params)
            return SchedulingResult(
                state: .review, stability: max(newS, 0.01), difficulty: newD,
                dueAt: now.addingTimeInterval(Double(interval) * 86400),
                scheduledDays: interval, elapsedDays: elapsedDays
            )
        }
    }

    // MARK: - Core Formulas

    /// The forgetting curve: R(t) = (1 + t / (9 * S))^(-1)
    private static func forgettingCurve(elapsedDays: Int, stability: Double) -> Double {
        guard stability > 0 else { return 0 }
        return pow(1 + Double(elapsedDays) / (9 * stability), -1)
    }

    /// Compute the interval in days for a target retention.
    private static func nextInterval(stability: Double, params: Parameters) -> Int {
        guard stability > 0 else { return 1 }
        let interval = 9 * stability * (1 / params.requestedRetention - 1)
        return min(max(Int(round(interval)), 1), params.maximumInterval)
    }

    /// Update difficulty after a review.
    private static func nextDifficulty(d: Double, rating: ReviewRating, params: Parameters) -> Double {
        let w = params.w
        let delta = d - w[6] * (Double(rating.rawValue) - 3)
        let newD = w[7..<w.count].isEmpty ? delta : clamp(delta, 1, 10)
        // Mean reversion
        let reverted = w[5..<w.count].count > 2
            ? w[4] * (1 - w[5]) + w[5] * newD
            : clamp(newD, 1, 10)
        return clamp(reverted, 1, 10)
    }

    private static func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, value))
    }
}
