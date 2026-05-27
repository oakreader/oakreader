import Foundation
import OakAI

/// Generates meeting summaries (highlights + action items) from transcripts.
actor RecordingSummaryService {

    struct MeetingSummary: Codable {
        let highlights: [String]
        let actionItems: [String]
    }

    /// Generate a summary from a transcript using the configured AI provider.
    /// Falls back to keyword-based extraction if no AI provider is available.
    func generateSummary(transcript: String) async throws -> MeetingSummary {
        let prefs = Preferences.shared
        let providerId = prefs.aiProviderId
        let defaultModel = ProviderRegistry.shared.provider(for: providerId)?.defaultModelId ?? ""
        let model = prefs.aiModel.isEmpty ? defaultModel : prefs.aiModel

        // Try AI-based summary first
        do {
            let config = ProviderConfig(providerId: providerId, model: model)
            let router = ProviderRouter()
            let provider = try router.provider(for: config)

            let systemPrompt = """
                You are a meeting notes assistant. Analyze the transcript and produce a JSON object with exactly two keys:
                - "highlights": array of 3-7 concise bullet points summarizing the key discussion points
                - "actionItems": array of specific action items, tasks, or follow-ups mentioned

                Respond ONLY with valid JSON, no markdown fencing or explanation.
                """

            let userMessage = LLMMessage(role: .user, text: "Transcript:\n\n\(transcript)")
            let stream = provider.sendMessage(
                messages: [userMessage],
                model: model,
                systemPrompt: systemPrompt,
                maxTokens: 2048
            )

            var responseText = ""
            for try await chunk in stream {
                switch chunk {
                case .delta(let text):
                    responseText += text
                case .thinking:
                    break
                case .finished, .error:
                    break
                case .toolUse, .toolInputDelta:
                    break
                }
            }

            // Parse JSON response
            let cleaned = responseText
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let data = cleaned.data(using: .utf8),
               let summary = try? JSONDecoder().decode(MeetingSummary.self, from: data) {
                return summary
            }

            // If JSON parsing fails, try to extract from response text
            return extractFromText(responseText)
        } catch {
            // Fallback to keyword-based extraction
            Log.info(Log.audio, "AI summary unavailable, using keyword extraction: \(error.localizedDescription)")
            return keywordBasedSummary(transcript: transcript)
        }
    }

    /// Extract summary from free-text AI response if JSON parsing fails.
    private func extractFromText(_ text: String) -> MeetingSummary {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var highlights: [String] = []
        var actionItems: [String] = []
        var inActionItems = false

        for line in lines {
            let lower = line.lowercased()
            if lower.contains("action item") || lower.contains("follow-up") || lower.contains("next step") {
                inActionItems = true
                continue
            }
            if lower.contains("highlight") || lower.contains("key point") || lower.contains("summary") {
                inActionItems = false
                continue
            }

            let cleaned = line
                .replacingOccurrences(of: "^[-*•\\d.]+\\s*", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)

            if cleaned.isEmpty { continue }

            if inActionItems {
                actionItems.append(cleaned)
            } else {
                highlights.append(cleaned)
            }
        }

        return MeetingSummary(highlights: highlights, actionItems: actionItems)
    }

    /// Keyword-based fallback when no AI provider is configured.
    /// Extracts action items by looking for common action patterns.
    private func keywordBasedSummary(transcript: String) -> MeetingSummary {
        let sentences = transcript.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 10 }

        let actionKeywords = [
            "should", "will", "need to", "action item", "follow up",
            "let's", "make sure", "don't forget", "remind", "deadline",
            "assign", "schedule", "set up", "create", "send",
        ]

        var actionItems: [String] = []
        var otherSentences: [String] = []

        for sentence in sentences {
            let lower = sentence.lowercased()
            if actionKeywords.contains(where: { lower.contains($0) }) {
                actionItems.append(sentence)
            } else {
                otherSentences.append(sentence)
            }
        }

        // Take up to 7 longest sentences as highlights (length often correlates with importance)
        let highlights = Array(
            otherSentences
                .sorted { $0.count > $1.count }
                .prefix(7)
        )

        return MeetingSummary(
            highlights: highlights,
            actionItems: Array(actionItems.prefix(10))
        )
    }
}
