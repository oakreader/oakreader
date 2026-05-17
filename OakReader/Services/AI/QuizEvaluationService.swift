import Foundation
import OakAI

/// Evaluates user answers against quiz card content using AI.
@Observable
class QuizEvaluationService {
    private(set) var isEvaluating = false

    /// Evaluate a user's answer against the expected card content.
    /// Returns an `EvaluationResult` with correctness, optional explanation, and the correct answer.
    func evaluate(
        userAnswer: String,
        card: QuizCard,
        feedbackMode: EvaluationFeedbackMode
    ) async throws -> EvaluationResult {
        isEvaluating = true
        defer { isEvaluating = false }

        let correctAnswer = extractCorrectAnswer(from: card)

        let prefs = Preferences.shared
        let providerId = prefs.aiProviderId
        let defaultModel = ProviderRegistry.shared.provider(for: providerId)?.defaultModelId ?? ""
        let model = prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel

        let config = ProviderConfig(providerId: providerId, model: model)
        let router = ProviderRouter()
        let provider = try router.provider(for: config)

        let systemPrompt = buildSystemPrompt(feedbackMode: feedbackMode)
        let userMessage = buildUserMessage(
            userAnswer: userAnswer,
            card: card,
            correctAnswer: correctAnswer
        )

        let stream = provider.sendMessage(
            messages: [LLMMessage(role: .user, text: userMessage)],
            model: model,
            systemPrompt: systemPrompt,
            maxTokens: 512
        )

        var fullResponse = ""
        for try await chunk in stream {
            switch chunk {
            case .delta(let text):
                fullResponse += text
            case .thinking, .toolUse, .finished:
                break
            case .error(let msg):
                throw QuizEvaluationError.aiError(msg)
            }
        }

        guard !fullResponse.isEmpty else {
            throw QuizEvaluationError.emptyResponse
        }

        return parseResponse(fullResponse, correctAnswer: correctAnswer)
    }

    // MARK: - Extract Correct Answer

    private func extractCorrectAnswer(from card: QuizCard) -> String {
        switch card.content {
        case .flashcard(let c):
            return c.back
        case .cloze(let c):
            // Extract answers from cloze markers
            let pattern = #"\{\{c\d+::([^}]*?)(?:::[^}]*)?\}\}"#
            let regex = try? NSRegularExpression(pattern: pattern)
            let matches = regex?.matches(in: c.text, range: NSRange(c.text.startIndex..., in: c.text)) ?? []
            let answers = matches.compactMap { match -> String? in
                guard let range = Range(match.range(at: 1), in: c.text) else { return nil }
                return String(c.text[range])
            }
            return answers.joined(separator: ", ")
        case .choice(let c):
            return c.choices[c.correctIndex]
        case .matching(let c):
            return c.pairs.map { "\($0.left) → \($0.right)" }.joined(separator: "; ")
        case .ordering(let c):
            return c.items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "; ")
        case .occlusion:
            return ""
        }
    }

    // MARK: - Prompt Construction

    private func buildSystemPrompt(feedbackMode: EvaluationFeedbackMode) -> String {
        let base = """
        You are a quiz answer evaluator for a spaced repetition system. Your job is to determine whether the user's answer is correct.

        ## Evaluation Rules
        - Be lenient on spelling, grammar, and word order
        - Focus on whether the core concept/meaning is correct
        - Accept synonyms and paraphrases that convey the same meaning
        - Minor omissions of non-essential details should still count as correct
        - Completely wrong or unrelated answers are incorrect

        ## Output Format
        Respond with ONLY a JSON object (no markdown fencing):
        """

        switch feedbackMode {
        case .simple:
            return base + """

            {"correct": true}
            or
            {"correct": false}
            """
        case .detailed:
            return base + """

            {"correct": true, "explanation": "Brief explanation of why"}
            or
            {"correct": false, "explanation": "Brief explanation of what was wrong and the key concept"}
            """
        }
    }

    private func buildUserMessage(userAnswer: String, card: QuizCard, correctAnswer: String) -> String {
        var message = "## Question\n"

        switch card.content {
        case .flashcard(let c):
            message += c.front
        case .cloze(let c):
            let hidden = c.text.replacingOccurrences(
                of: #"\{\{c\d+::([^}]*?)(?:::[^}]*)?\}\}"#,
                with: "[___]",
                options: .regularExpression
            )
            message += hidden
        case .choice(let c):
            message += c.question
        case .matching(let c):
            message += "Match the pairs:\n"
            message += c.pairs.map { "- \($0.left)" }.joined(separator: "\n")
        case .ordering(let c):
            message += c.prompt
        case .occlusion:
            message += "Image occlusion"
        }

        message += "\n\n## Expected Answer\n\(correctAnswer)"
        message += "\n\n## User's Answer\n\(userAnswer)"

        return message
    }

    // MARK: - Response Parsing

    private func parseResponse(_ response: String, correctAnswer: String) -> EvaluationResult {
        // Try JSON parsing first
        let cleaned = response
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let data = cleaned.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let correct = json["correct"] as? Bool {
            let explanation = json["explanation"] as? String
            return EvaluationResult(
                isCorrect: correct,
                explanation: explanation,
                correctAnswer: correctAnswer
            )
        }

        // Regex fallback: look for "correct": true/false
        let truePattern = #""correct"\s*:\s*true"#
        let falsePattern = #""correct"\s*:\s*false"#

        if response.range(of: truePattern, options: .regularExpression) != nil {
            return EvaluationResult(isCorrect: true, explanation: nil, correctAnswer: correctAnswer)
        } else if response.range(of: falsePattern, options: .regularExpression) != nil {
            return EvaluationResult(isCorrect: false, explanation: nil, correctAnswer: correctAnswer)
        }

        // Final fallback: mark as incorrect to be safe (user can override)
        return EvaluationResult(isCorrect: false, explanation: nil, correctAnswer: correctAnswer)
    }
}

// MARK: - Errors

enum QuizEvaluationError: LocalizedError {
    case aiError(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .aiError(let msg): return "Evaluation failed: \(msg)"
        case .emptyResponse: return "AI returned an empty response"
        }
    }
}
