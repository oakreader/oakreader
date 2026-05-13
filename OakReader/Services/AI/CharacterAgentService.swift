import Foundation
import OakAgent

struct CharacterAgentThreadMessage: Codable, Sendable {
    let id: UUID
    let role: String
    let content: String
    let timestamp: Date
}

struct CharacterAgentRunResult: Sendable {
    let agent: CharacterAgent
    let threadRef: CharacterAgentThreadRef
    let output: String

    var xmlBlock: String {
        """
        <character-agent-input agent_id="\(Self.escapeAttribute(agent.id))" agent_name="\(Self.escapeAttribute(agent.name))" icon="\(Self.escapeAttribute(agent.icon))" thread_id="\(threadRef.id.uuidString)" jsonl_path="\(Self.escapeAttribute(threadRef.jsonlPath))">
        \(output.trimmingCharacters(in: .whitespacesAndNewlines))
        </character-agent-input>
        """
    }

    private static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

struct CharacterAgentService: Sendable {
    private let router = ProviderRouter()

    func run(
        agent: CharacterAgent,
        request: String,
        contextSystemPrompt: String,
        config: ProviderConfig
    ) async throws -> CharacterAgentRunResult {
        let threadId = UUID()
        let threadURL = CatalogDatabase.characterAgentThreadURL(threadId: threadId)
        try FileManager.default.createDirectory(
            at: CatalogDatabase.characterAgentThreadsDirectory,
            withIntermediateDirectories: true
        )

        let trimmedRequest = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let userRequest = trimmedRequest.isEmpty
            ? "Provide your perspective on the current context."
            : trimmedRequest

        try appendThreadMessage(
            CharacterAgentThreadMessage(id: UUID(), role: "user", content: userRequest, timestamp: Date()),
            to: threadURL
        )

        let systemPrompt = """
        \(agent.prompt)

        You are not the main chat assistant. Your job is to produce delegated user-role material for the main assistant.
        Write a compact digest in your inspired method/style. Do not address the user as if you are the final assistant.
        Do not impersonate or claim identity as \(agent.name).

        App/document context available to you:
        \(contextSystemPrompt)
        """

        let provider = try router.provider(for: config)
        let stream = provider.sendMessage(
            messages: [LLMMessage(role: .user, text: userRequest)],
            model: config.model,
            systemPrompt: systemPrompt,
            maxTokens: min(config.maxTokens, 2_000)
        )

        var output = ""
        for try await chunk in stream {
            switch chunk {
            case .delta(let text):
                output += text
            case .finished(_):
                break
            case .toolUse:
                break
            case .error(let message):
                throw LLMProviderError.streamError(message)
            }
        }

        let finalOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        try appendThreadMessage(
            CharacterAgentThreadMessage(id: UUID(), role: "character_agent", content: finalOutput, timestamp: Date()),
            to: threadURL
        )

        let now = Date()
        let ref = CharacterAgentThreadRef(
            id: threadId,
            agentId: agent.id,
            agentName: agent.name,
            icon: agent.icon,
            jsonlPath: threadURL.path,
            status: .completed,
            title: String(userRequest.prefix(80)),
            summary: String(finalOutput.prefix(500)),
            latestUserFollowUp: nil,
            createdAt: now,
            updatedAt: now
        )

        return CharacterAgentRunResult(agent: agent, threadRef: ref, output: finalOutput)
    }

    private func appendThreadMessage(_ message: CharacterAgentThreadMessage, to url: URL) throws {
        let data = try JSONEncoder().encode(message)
        guard var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            if let lineData = line.data(using: .utf8) {
                handle.write(lineData)
            }
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
