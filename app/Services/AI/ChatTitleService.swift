import Foundation

/// Generates a short, human-readable title for a chat.
///
/// Named from the first message, as soon as it is sent, so the title arrives
/// while the answer streams instead of after it. Cursor names a chat the same
/// way; the rules below follow its local naming prompt (a 2–6 word topic,
/// never an answer, 48 characters at most).
///
/// Runs off the hot path as a single no-tools completion. Fail-soft: any error returns `nil` and
/// the caller keeps the existing placeholder title (truncated first message).
struct ChatTitleService {
    /// Max characters of the message fed to the model.
    private static let inputClip = 2000
    /// Longest title kept.
    private static let maxLength = 48

    private static let system = """
    You name a chat from the user's first message, for display in a chat header and history list.
    Rules:
    - Name the topic of the request. Do not answer it.
    - A short noun phrase of 2 to 6 words. Do not start with a verb. Never a full sentence.
    - Same language as the message.
    - No surrounding quotes, no trailing punctuation, no markdown.
    Output ONLY the name.
    """

    /// Returns a cleaned title, or `nil` on any failure / empty result.
    /// `reply` is given only when the message alone says too little, such as
    /// a message that is only a skill.
    static func generate(firstMessage: String, reply: String? = nil, config: AIRequestConfig) async -> String? {
        var user = "Message: \(firstMessage.prefix(inputClip))"
        if let reply { user += "\n\nReply: \(reply.prefix(600))" }

        guard let raw = await complete(system: system, user: user, config: config) else { return nil }
        let title = clean(raw)
        return title.isEmpty ? nil : title
    }

    // MARK: - Private

    /// Single no-tools completion through the completion facade.
    private static func complete(system: String, user: String, config: AIRequestConfig) async -> String? {
        let request = CompletionRequest(
            providerId: config.providerId, model: config.model,
            system: system, user: user, maxTokens: 200
        )
        var streamed = ""
        do {
            for try await delta in AIBackend.completions.stream(request) {
                streamed += delta
            }
        } catch {
            return nil
        }
        let result = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Strip stray quotes / code fences / trailing punctuation and clamp length.
    private static func clean(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```"), let nl = s.firstIndex(of: "\n") {
            s = String(s[s.index(after: nl)...])
            if let fence = s.range(of: "```", options: .backwards) {
                s = String(s[..<fence.lowerBound])
            }
        }
        // Take just the first line — models sometimes add an explanation below.
        s = s.split(separator: "\n").first.map(String.init) ?? s
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`.。!?;:,！？；：，“”"))
        return String(s.prefix(maxLength))
    }
}
