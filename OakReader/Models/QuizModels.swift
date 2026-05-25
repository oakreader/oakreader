import Foundation

// MARK: - Quiz Type

enum QuizType: String, Codable, CaseIterable, Identifiable {
    case cloze
    case choice
    case flashcard
    case occlusion
    case matching
    case ordering

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cloze: return "Cloze"
        case .choice: return "Choice"
        case .flashcard: return "Flashcard"
        case .occlusion: return "Occlusion"
        case .matching: return "Matching"
        case .ordering: return "Ordering"
        }
    }

    var systemImage: String {
        switch self {
        case .cloze: return "text.redaction"
        case .choice: return "checklist"
        case .flashcard: return "rectangle.on.rectangle.angled"
        case .occlusion: return "eye.slash"
        case .matching: return "arrow.left.arrow.right"
        case .ordering: return "list.number"
        }
    }
}

// MARK: - Card State (FSRS)

enum QuizCardState: String, Codable {
    case new
    case learning
    case review
    case relearning
}

// MARK: - Review Rating (FSRS)

enum ReviewRating: Int, Codable, CaseIterable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4

    var label: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }
}

// MARK: - Quiz Content (type-specific payloads)

enum QuizContent: Codable, Hashable {
    case cloze(ClozeContent)
    case choice(ChoiceContent)
    case flashcard(FlashcardContent)
    case occlusion(OcclusionContent)
    case matching(MatchingContent)
    case ordering(OrderingContent)

    struct ClozeContent: Codable, Hashable {
        let text: String           // "The {{c1::heart}} pumps {{c2::blood}}"
        let hint: String?
    }

    struct ChoiceContent: Codable, Hashable {
        let question: String
        let choices: [String]
        let correctIndex: Int      // 0-based
        let explanation: String?
    }

    struct FlashcardContent: Codable, Hashable {
        let front: String          // Markdown
        let back: String           // Markdown
    }

    struct OcclusionContent: Codable, Hashable {
        let imageURL: String       // relative path or base64
        let masks: [[String: Double]]  // [{x, y, w, h}]
        let labels: [String]
    }

    struct MatchingContent: Codable, Hashable {
        let pairs: [Pair]
        struct Pair: Codable, Hashable {
            let left: String
            let right: String
        }
    }

    struct OrderingContent: Codable, Hashable {
        let prompt: String
        let items: [String]        // Correct order
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, data
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "cloze":
            self = .cloze(try container.decode(ClozeContent.self, forKey: .data))
        case "choice":
            self = .choice(try container.decode(ChoiceContent.self, forKey: .data))
        case "flashcard":
            self = .flashcard(try container.decode(FlashcardContent.self, forKey: .data))
        case "occlusion":
            self = .occlusion(try container.decode(OcclusionContent.self, forKey: .data))
        case "matching":
            self = .matching(try container.decode(MatchingContent.self, forKey: .data))
        case "ordering":
            self = .ordering(try container.decode(OrderingContent.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container,
                debugDescription: "Unknown quiz type '\(type)'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cloze(let c):
            try container.encode("cloze", forKey: .type)
            try container.encode(c, forKey: .data)
        case .choice(let c):
            try container.encode("choice", forKey: .type)
            try container.encode(c, forKey: .data)
        case .flashcard(let c):
            try container.encode("flashcard", forKey: .type)
            try container.encode(c, forKey: .data)
        case .occlusion(let c):
            try container.encode("occlusion", forKey: .type)
            try container.encode(c, forKey: .data)
        case .matching(let c):
            try container.encode("matching", forKey: .type)
            try container.encode(c, forKey: .data)
        case .ordering(let c):
            try container.encode("ordering", forKey: .type)
            try container.encode(c, forKey: .data)
        }
    }

    var quizType: QuizType {
        switch self {
        case .cloze: return .cloze
        case .choice: return .choice
        case .flashcard: return .flashcard
        case .occlusion: return .occlusion
        case .matching: return .matching
        case .ordering: return .ordering
        }
    }
}

// MARK: - Quiz Deck (grouped cards for carousel display)

/// A group of quiz cards wrapped in a `<deck>` tag, displayed as a navigable
/// carousel in the chat. Each card can be individually saved to the review deck.
struct QuizDeck: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let cards: [QuizContent]
}

// MARK: - QuizCard (view-facing model)

struct QuizCard: Identifiable, Hashable {
    let id: UUID
    let itemId: String
    var conversationId: String?
    var groupId: String?
    let type: QuizType
    let content: QuizContent
    var state: QuizCardState
    var dueAt: Date
    var stability: Double
    var difficulty: Double
    var elapsedDays: Int
    var scheduledDays: Int
    var reps: Int
    var lapses: Int
    var lastReviewAt: Date?
    var isSuspended: Bool
    var annotationId: String?
    var sourceText: String?
    var pageContext: String?
    var isPending: Bool
    var createdAt: Date
    var updatedAt: Date

    /// Whether this card is currently due for review.
    var isDue: Bool {
        !isSuspended && dueAt <= Date()
    }

    /// Summary text for list display.
    var displayTitle: String {
        switch content {
        case .cloze(let c):
            // Strip cloze markers for display
            return c.text.replacingOccurrences(
                of: #"\{\{c\d+::([^}]*?)(?:::[^}]*)?\}\}"#,
                with: "___",
                options: .regularExpression
            )
        case .choice(let c):
            return c.question
        case .flashcard(let c):
            return c.front
        case .occlusion:
            return "Image Occlusion"
        case .matching(let c):
            return "Match: \(c.pairs.first?.left ?? "")\u{2026}"
        case .ordering(let c):
            return c.prompt
        }
    }

    // MARK: - Record conversion

    init(record: QuizCardRecord) {
        self.id = UUID(uuidString: record.id) ?? UUID()
        self.itemId = record.itemId
        self.conversationId = record.conversationId
        self.groupId = record.groupId
        self.type = QuizType(rawValue: record.type) ?? .flashcard
        self.content = (try? JSONDecoder().decode(QuizContent.self, from: Data(record.contentJson.utf8))) ?? .flashcard(.init(front: "?", back: "?"))
        self.state = QuizCardState(rawValue: record.state) ?? .new
        self.dueAt = Date(iso8601String: record.dueAt) ?? Date()
        self.stability = record.stability
        self.difficulty = record.difficulty
        self.elapsedDays = record.elapsedDays
        self.scheduledDays = record.scheduledDays
        self.reps = record.reps
        self.lapses = record.lapses
        self.lastReviewAt = record.lastReviewAt.flatMap { Date(iso8601String: $0) }
        self.isSuspended = record.isSuspended
        self.annotationId = record.annotationId
        self.sourceText = record.sourceText
        self.pageContext = record.pageContext
        self.isPending = record.isPending
        self.createdAt = Date(iso8601String: record.createdAt) ?? Date()
        self.updatedAt = Date(iso8601String: record.updatedAt) ?? Date()
    }
}
