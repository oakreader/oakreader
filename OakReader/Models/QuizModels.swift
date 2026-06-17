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
        /// 1-based source page the answer is grounded in (PDF only). `nil` when
        /// unknown or the source isn't paginated (HTML / markdown / media).
        let sourcePage: Int?
        /// A short verbatim excerpt the answer comes from — used to locate and
        /// highlight the passage in the document. `nil` when not provided.
        let sourceQuote: String?

        enum CodingKeys: String, CodingKey {
            case front, back
            case sourcePage = "source_page"
            case sourceQuote = "source_quote"
        }

        init(front: String, back: String, sourcePage: Int? = nil, sourceQuote: String? = nil) {
            self.front = front
            self.back = back
            self.sourcePage = sourcePage
            self.sourceQuote = sourceQuote
        }

        /// Tolerant decode: a model may emit `source_page` as a number *or* a
        /// string ("p. 12"), or omit it — none of which should drop the card.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            front = try c.decode(String.self, forKey: .front)
            back = try c.decode(String.self, forKey: .back)
            let quote = try? c.decodeIfPresent(String.self, forKey: .sourceQuote)
            sourceQuote = (quote?.isEmpty == true) ? nil : quote
            if let p = try? c.decodeIfPresent(Int.self, forKey: .sourcePage) {
                sourcePage = p
            } else if let s = try? c.decodeIfPresent(String.self, forKey: .sourcePage),
                      let p = Int(s.filter(\.isNumber)), p > 0 {
                sourcePage = p
            } else {
                sourcePage = nil
            }
        }
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

/// A group of quiz cards, displayed as a navigable carousel.
struct QuizDeck: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let cards: [QuizContent]
}

// MARK: - Card Codec

/// Encode/decode quiz cards stored as JSON. A Studio quiz artifact's body is a
/// `{ "title": ..., "cards": [{type,data}, …] }` object; this is the single
/// place that bridges that JSON and the `QuizDeck`/`QuizContent` model.
enum QuizCardCodec {
    /// Decode a deck from a `{ "title", "cards":[…] }` JSON object string.
    /// Cards that fail to decode are skipped; returns nil if none survive.
    static func deck(fromJSON json: String) -> QuizDeck? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cardsArray = obj["cards"] as? [Any]
        else { return nil }
        let cards = decodeCards(cardsArray)
        guard !cards.isEmpty else { return nil }
        return QuizDeck(title: obj["title"] as? String ?? "", cards: cards)
    }

    /// Decode an array of `{type,data}` JSON values into cards, skipping failures.
    static func decodeCards(_ values: [Any]) -> [QuizContent] {
        values.compactMap { element in
            guard let d = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return try? JSONDecoder().decode(QuizContent.self, from: d)
        }
    }

    /// Extract the complete card objects from a still-streaming raw JSON buffer
    /// (e.g. `{"title":"…","cards":[{…},{…},{…`). Finds the `cards` array and
    /// pulls each balanced `{…}` object via brace counting (ignoring braces
    /// inside strings), skipping a trailing half-written one — so a carousel can
    /// grow card-by-card as the model streams.
    static func cardsFromPartialJSON(_ raw: String) -> [QuizContent] {
        guard let keyRange = raw.range(of: "\"cards\"") else { return [] }
        let after = raw[keyRange.upperBound...]
        guard let openBracket = after.firstIndex(of: "[") else { return [] }

        let decoder = JSONDecoder()
        var cards: [QuizContent] = []
        var depth = 0
        var inString = false
        var escaped = false
        var buf = ""

        var i = after.index(after: openBracket)
        while i < after.endIndex {
            let c = after[i]
            defer { i = after.index(after: i) }

            if depth > 0 { buf.append(c) }

            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                inString.toggle()
            } else if !inString {
                if c == "{" {
                    if depth == 0 { buf = "{" }
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        if let data = buf.data(using: .utf8),
                           let card = try? decoder.decode(QuizContent.self, from: data) {
                            cards.append(card)
                        }
                        buf = ""
                    }
                } else if c == "]", depth == 0 {
                    break
                }
            }
        }
        return cards
    }

    /// Best-effort extract the `"title"` string value from a (possibly partial)
    /// JSON buffer.
    static func titleFromJSON(_ raw: String) -> String? {
        guard let keyRange = raw.range(of: "\"title\"") else { return nil }
        let after = raw[keyRange.upperBound...]
        guard let colon = after.firstIndex(of: ":") else { return nil }
        let rest = after[after.index(after: colon)...]
        guard let open = rest.firstIndex(of: "\"") else { return nil }
        var value = ""
        var escaped = false
        var i = rest.index(after: open)
        while i < rest.endIndex {
            let c = rest[i]
            if escaped { value.append(c); escaped = false }
            else if c == "\\" { escaped = true }
            else if c == "\"" { return value }
            else { value.append(c) }
            i = rest.index(after: i)
        }
        return nil  // closing quote not yet streamed
    }

    /// Encode a deck to the canonical `{ "title", "cards":[{type,data}] }` JSON
    /// string used as a Studio quiz artifact's body.
    static func bodyJSON(title: String, cards: [QuizContent]) -> String {
        let cardsData = (try? JSONEncoder().encode(cards)) ?? Data("[]".utf8)
        let cardsObj = (try? JSONSerialization.jsonObject(with: cardsData)) ?? []
        let wrapper: [String: Any] = ["title": title, "cards": cardsObj]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper),
              let str = String(data: data, encoding: .utf8)
        else { return "{\"title\":\"\",\"cards\":[]}" }
        return str
    }
}
