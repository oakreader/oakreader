import Foundation
import OakAI

/// Generates quiz cards from highlighted text using AI in the background.
@Observable
class QuizGenerationService {
    private let database: CatalogDatabase

    /// Whether a generation task is currently running.
    private(set) var isGenerating = false

    init(database: CatalogDatabase) {
        self.database = database
    }

    /// Generate quiz cards from highlighted text in background.
    /// Returns the created (pending) cards, or throws on failure.
    @discardableResult
    func generateFromHighlight(
        sourceText: String,
        pageContext: String,
        documentTitle: String,
        itemId: String,
        annotationId: String
    ) async throws -> [QuizCard] {
        isGenerating = true
        defer { isGenerating = false }

        let prefs = Preferences.shared
        let providerId = prefs.aiProviderId
        let defaultModel = ProviderRegistry.shared.provider(for: providerId)?.defaultModelId ?? ""
        let model = prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel

        let config = ProviderConfig(providerId: providerId, model: model)
        let router = ProviderRouter()
        let provider = try router.provider(for: config)

        let systemPrompt = buildSystemPrompt(documentTitle: documentTitle)
        let userMessage = buildUserMessage(sourceText: sourceText, pageContext: pageContext)

        let stream = provider.sendMessage(
            messages: [LLMMessage(role: .user, text: userMessage)],
            model: model,
            systemPrompt: systemPrompt,
            maxTokens: 2048
        )

        var fullResponse = ""
        for try await chunk in stream {
            switch chunk {
            case .delta(let text):
                fullResponse += text
            case .thinking, .toolUse, .finished:
                break
            case .error(let msg):
                throw QuizGenerationError.aiError(msg)
            }
        }

        guard !fullResponse.isEmpty else {
            throw QuizGenerationError.emptyResponse
        }

        // Parse quiz XML from response
        let segments = QuizXMLParser.parse(fullResponse)
        let quizContents: [QuizContent] = segments.compactMap {
            if case .quiz(let content) = $0 { return content }
            return nil
        }

        guard !quizContents.isEmpty else {
            throw QuizGenerationError.noCardsGenerated
        }

        // Save cards as pending
        let cardService = QuizCardService(database: database)
        var cards: [QuizCard] = []
        for content in quizContents {
            let card = try cardService.createCard(
                itemId: itemId,
                content: content,
                annotationId: annotationId,
                sourceText: sourceText,
                pageContext: pageContext,
                isPending: true
            )
            cards.append(card)
        }

        return cards
    }

    // MARK: - Prompt Construction

    private func buildSystemPrompt(documentTitle: String) -> String {
        """
        You are a quiz card generator for spaced repetition learning. Generate 1–3 high-quality quiz cards from the highlighted text provided by the user.

        ## Document
        Title: \(documentTitle)

        ## Guidelines
        - Create cards that test understanding, not just surface recall
        - Apply desirable difficulty: pitch questions slightly above simple recognition
        - Use elaborative interrogation: ask "why" and "how" questions when appropriate
        - Prefer cloze deletions for factual content, flashcards for conceptual understanding
        - Each card should be self-contained and make sense without the source context
        - Keep cards concise — the front/question should be a single clear prompt

        ## Output Format
        Wrap each card in a <quiz> XML tag. Supported types: cloze, flashcard, choice.

        ### Cloze
        <quiz type="cloze">
          <text>The {{c1::answer}} is hidden in context.</text>
        </quiz>

        ### Flashcard
        <quiz type="flashcard">
          <front>Question or prompt</front>
          <back>Answer or explanation</back>
        </quiz>

        ### Multiple Choice
        <quiz type="choice">
          <question>What is X?</question>
          <option correct="true">Correct answer</option>
          <option>Wrong answer 1</option>
          <option>Wrong answer 2</option>
          <option>Wrong answer 3</option>
        </quiz>

        Output ONLY the quiz XML tags with minimal surrounding text. Do not include explanations or commentary outside the quiz tags.
        """
    }

    private func buildUserMessage(sourceText: String, pageContext: String) -> String {
        var message = "Generate quiz cards from this highlighted text:\n\n"
        message += "## Highlighted Text\n\(sourceText)\n\n"
        if !pageContext.isEmpty && pageContext != sourceText {
            message += "## Surrounding Page Context\n\(pageContext)\n"
        }
        return message
    }
}

// MARK: - Errors

enum QuizGenerationError: LocalizedError {
    case aiError(String)
    case emptyResponse
    case noCardsGenerated

    var errorDescription: String? {
        switch self {
        case .aiError(let msg): return "AI error: \(msg)"
        case .emptyResponse: return "AI returned an empty response"
        case .noCardsGenerated: return "No quiz cards could be parsed from the response"
        }
    }
}
