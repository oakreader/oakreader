import Foundation
import OakAgent

/// Generates a short, human-readable title for a chat from its first exchange.
///
/// Runs off the hot path as a single no-tools completion (mirrors
/// `MemoryReflectionService.complete`). Fail-soft: any error returns `nil` and
/// the caller keeps the existing placeholder title (truncated first message).
struct ChatTitleService {
    /// Max characters of each side of the exchange we feed the model. The first
    /// turn is what carries the intent; we don't need the whole thing.
    private static let inputClip = 600

    private static let system = """
    You write a short title for a conversation, for display in a chat sidebar.
    Rules:
    - 3 to 6 words. Never a full sentence.
    - Capture the user's task or intent, not pleasantries.
    - Same language as the conversation.
    - No surrounding quotes, no trailing punctuation, no markdown.
    Output ONLY the title.
    """

    /// Returns a cleaned title, or `nil` on any failure / empty result.
    static func generate(firstUser: String, firstAssistant: String, config: ProviderConfig) async -> String? {
        let user = """
        User: \(firstUser.prefix(inputClip))

        Assistant: \(firstAssistant.prefix(inputClip))
        """

        guard let raw = await complete(system: system, user: user, config: config) else { return nil }
        let title = clean(raw)
        return title.isEmpty ? nil : title
    }

    // MARK: - Private

    /// Single no-tools completion via an ephemeral session in a temp dir.
    private static func complete(system: String, user: String, config: ProviderConfig) async -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("oak-title-\(UUID().uuidString)", isDirectory: true)
        let session = AgentSession(chatsDirectory: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var streamed = ""
        var finalText: String?
        do {
            let stream = await session.send(
                userContent: user,
                attachments: [],
                history: [],
                sessionId: UUID(),
                config: config,
                systemPrompt: system,
                tools: nil,
                toolContext: nil,
                maxIterations: 1
            )
            for try await event in stream {
                switch event {
                case .delta(let d):
                    streamed += d
                case .finished(let turn) where turn.role == .assistant:
                    finalText = turn.content
                default:
                    break
                }
            }
        } catch {
            return nil
        }

        let result = (finalText ?? streamed).trimmingCharacters(in: .whitespacesAndNewlines)
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
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`.。"))
        return String(s.prefix(60))
    }
}
