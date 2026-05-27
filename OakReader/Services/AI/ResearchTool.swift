import Foundation
import OakAgent

/// A research **subagent**: runs its own nested, read-only agent loop over the
/// library (full-text search + document reading) and returns only a cited
/// synthesis. The verbose search/read iterations stay in the child's isolated
/// context, keeping the main conversation clean — the "context multiplication"
/// pattern used by Claude Code and Amp.
///
/// Use it for deep questions that span many documents; a single quick lookup
/// should call `search_content` directly instead (a subagent has real cost and
/// latency: it makes several LLM calls of its own).
struct ResearchTool: AgentTool, Sendable {
    let name = "research"
    let category: ToolCategory = .readOnly
    let description = """
        Delegate a deep, multi-document research question to a focused research \
        subagent over the user's library. The subagent iteratively searches the \
        full text, reads the most relevant passages, and returns a concise synthesis \
        with citations. Prefer this for broad/synthetic questions ("what does my \
        library say about X across papers", "compare how these sources treat Y"). \
        For a single fact or a quick "do I have anything on Z", call search_content \
        directly instead — this tool is slower and more expensive because it runs its \
        own agent loop. Returns a written answer with oak:// citations.
        """

    /// Full-text search service shared with the parent (read-only use here).
    let searchService: SemanticIndexService
    /// LLM provider/model config inherited from the parent chat.
    let config: ProviderConfig

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "question": [
                    "type": "string",
                    "description":
                        "The research question to investigate against the user's library."
                ]
            ],
            "required": ["question"]
        ]
    }

    private static let systemPrompt = """
        You are a research assistant working over the user's personal document library. \
        Answer the question using ONLY evidence found in the library — do not rely on prior knowledge.

        Method:
        1. Decompose the question into sub-topics.
        2. Use `search_content` to find relevant passages (refine your keywords and search again \
           if results are thin or off-target; vary terms across a few queries).
        3. Use the `oak` tool to read the most promising documents at their cited pages \
           (e.g. `items read <citeKey> --pages 3-6`).
        4. Synthesize a concise, well-structured answer.

        Citations are required: back every claim with an inline citation in the form \
        `oak://cite/{citeKey}?page=N` so the answer links to the exact source page. \
        If the library contains nothing relevant, say so plainly rather than inventing an answer.
        """

    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolOutput {
        guard let question = input["question"], !question.isEmpty else {
            return .error("Missing required parameter: question")
        }

        // Isolated, ephemeral session directory so research loops never clutter the
        // user's saved chat history.
        let sessionDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("oak-research-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionDir) }

        let child = AgentSession(chatsDirectory: sessionDir)

        // Restricted toolset: search + read only. Notably NOT the research tool itself
        // (no recursion), and no write/web/memory tools.
        let childTools: [any AgentTool] = [
            SemanticSearchTool(service: searchService),
            OakCLITool()
        ]
        // A toolContext is mandatory — AgentSession silently drops tool calls when it
        // is nil. Read-only access scoped to the app data directory.
        let childContext = ToolExecutionContext(
            workingDirectory: sessionDir,
            allowedPaths: [CatalogDatabase.dataDirectory]
        )

        let stream = await child.send(
            userContent: question,
            attachments: [],
            history: [],
            sessionId: UUID(),
            config: config,
            systemPrompt: Self.systemPrompt,
            tools: childTools,
            toolContext: childContext,
            maxIterations: 8
        )

        // The synthesis is the last assistant turn (the one emitted with no further
        // tool calls). Intermediate assistant turns are overwritten as we go.
        var answer = ""
        do {
            for try await event in stream {
                if case .finished(let turn) = event, turn.role == .assistant {
                    answer = turn.content
                }
            }
        } catch {
            return .error("Research subagent failed: \(error.localizedDescription)")
        }

        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? .success("The research subagent did not produce an answer.")
            : .success(trimmed)
    }
}
