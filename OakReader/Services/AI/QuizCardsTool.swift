import Foundation
import OakAgent

/// Renders a group of quiz cards inline in the chat as a card carousel. The
/// model passes the cards directly as the tool input; the carousel UI is drawn
/// from `ToolUseRecord.input` in `ChatBubbleView`, which dispatches each card to
/// its type-specific view (flashcard, cloze, occlusion).
///
/// Execution itself only validates and acknowledges — the cards are *rendered*
/// from the tool input and live in the chat history that produced them. There is
/// no separate store: this keeps the tool free of database access.
///
/// Cards travel as a structured `cards` array (`[{type, data}]`) — tool input is
/// now structured JSON (`ToolInput`/`JSONValue`), so no NDJSON-string workaround
/// is needed.
struct QuizCardsTool: AgentTool, Sendable {
    let name = "quiz_cards"
    let description = """
        Render quiz cards for the user as an interactive card carousel in the chat. \
        Use this whenever the user wants to be quizzed, asks for flashcards, or wants \
        to review or memorize material. Pass the cards directly through this tool — do \
        NOT write quiz markup or card XML in your text reply. Choose the card type that \
        best fits each piece of material: prefer flashcard or cloze for conceptual \
        understanding and free recall. All text fields are Markdown.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "Optional short title for the card group."
                ] as [String: Any],
                "cards": [
                    "type": "array",
                    "description": """
                        The cards. Each item is {"type":"<type>","data":{...}} where \
                        <type> and its data are one of:
                        • flashcard — {"front": md, "back": md}
                        • cloze — {"text": "... {{c1::answer}} ...", "hint": md?}  (use {{c1::...}}, {{c2::...}} for blanks)
                        """,
                    "items": [
                        "type": "object",
                        "properties": [
                            "type": ["type": "string"] as [String: Any],
                            "data": ["type": "object"] as [String: Any]
                        ] as [String: Any],
                        "required": ["type", "data"]
                    ] as [String: Any]
                ] as [String: Any]
            ] as [String: Any],
            "required": ["cards"]
        ]
    }

    init() {}

    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolOutput {
        guard let cardValues = input.array("cards"), !cardValues.isEmpty else {
            return .error("Missing required parameter: cards (an array of {\"type\",\"data\"} objects)")
        }
        let cards = cardValues.compactMap { Self.decodeCard($0) }
        guard !cards.isEmpty else {
            return .error(
                #"cards must be objects like {"type":"flashcard","data":{"front":"...","back":"..."}}."#
            )
        }

        let titleSuffix = input["title"].flatMap { $0.isEmpty ? nil : " \"\($0)\"" } ?? ""
        return .success(
            "Rendered \(cards.count) quiz card(s)\(titleSuffix) to the user as an "
                + "interactive carousel in the chat."
        )
    }

    /// Reconstruct a `QuizDeck` from a persisted `quiz_cards` tool-use record.
    /// Returns nil if the record carries no decodable cards. Used to surface
    /// cards from chat history (e.g. the per-item Quiz Cards panel).
    static func deck(from record: ToolUseRecord) -> QuizDeck? {
        guard let cardValues = record.input.array("cards") else { return nil }
        let cards = cardValues.compactMap { decodeCard($0) }
        guard !cards.isEmpty else { return nil }
        return QuizDeck(title: record.input["title"] ?? "", cards: cards)
    }

    /// Decode a single `{type, data}` JSON value into a `QuizContent`.
    static func decodeCard(_ value: JSONValue) -> QuizContent? {
        guard JSONSerialization.isValidJSONObject(value.anyValue),
              let data = try? JSONSerialization.data(withJSONObject: value.anyValue)
        else { return nil }
        return try? JSONDecoder().decode(QuizContent.self, from: data)
    }
}
