import Foundation

// MARK: - Quiz Type

enum QuizType: String, Codable, CaseIterable, Identifiable {
    case cloze
    case flashcard
    case occlusion

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cloze: return "Cloze"
        case .flashcard: return "Flashcard"
        case .occlusion: return "Occlusion"
        }
    }

    var systemImage: String {
        switch self {
        case .cloze: return "text.redaction"
        case .flashcard: return "rectangle.on.rectangle.angled"
        case .occlusion: return "eye.slash"
        }
    }
}

// MARK: - Quiz Content (type-specific payloads)

enum QuizContent: Codable, Hashable {
    case cloze(ClozeContent)
    case flashcard(FlashcardContent)
    case occlusion(OcclusionContent)

    struct ClozeContent: Codable, Hashable {
        let text: String           // "The {{c1::heart}} pumps {{c2::blood}}"
        let hint: String?
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
        case "flashcard":
            self = .flashcard(try container.decode(FlashcardContent.self, forKey: .data))
        case "occlusion":
            self = .occlusion(try container.decode(OcclusionContent.self, forKey: .data))
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
        case .flashcard(let c):
            try container.encode("flashcard", forKey: .type)
            try container.encode(c, forKey: .data)
        case .occlusion(let c):
            try container.encode("occlusion", forKey: .type)
            try container.encode(c, forKey: .data)
        }
    }

    var quizType: QuizType {
        switch self {
        case .cloze: return .cloze
        case .flashcard: return .flashcard
        case .occlusion: return .occlusion
        }
    }
}

// MARK: - Quiz Deck (grouped cards for carousel display)

/// A group of quiz cards wrapped in a `<deck>` tag, displayed as a navigable
/// carousel in the chat. Cards live in the chat history that produced them.
struct QuizDeck: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let cards: [QuizContent]
}
