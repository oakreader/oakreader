import Foundation
import OakAgent

// MARK: - Remember Tool
//
// The single hot-path memory affordance. Everything else about the user's profile
// is maintained automatically in the background by `MemoryReflectionService`
// (per-fact ADD/UPDATE/DELETE against `MemoryStore`). This tool exists only for the
// explicit "remember that …" case: the user states a durable fact or preference
// they want kept across sessions.
//
// It writes one discrete, *pinned* fact to the user memory store (pinned because
// the human asserted it, so background reflection must never quietly drop it).

/// Save a durable, user-stated fact to the user memory store.
struct RememberTool: AgentTool {
    let name = "remember"
    let description = """
        Save a durable fact or preference the user explicitly wants remembered \
        across sessions — who they are, what they're working toward, or how they \
        want you to respond (e.g. "I'm a backend engineer", "always answer in \
        Chinese", "give me intuition before formalism"). \
        Use this ONLY for lasting, user-stated facts — never for routine Q&A, \
        transient context, or your own inferences about their understanding. \
        One concise line. Observe silently; do not announce that you saved it.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "fact": [
                    "type": "string",
                    "description": "One concise line stating the durable fact or preference, in the user's terms."
                ]
            ],
            "required": ["fact"]
        ]
    }

    var category: ToolCategory { .write }

    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolOutput {
        guard var fact = input["fact"], !fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ToolOutput(content: "Error: 'fact' parameter is required.")
        }
        fact = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        if fact.count > 200 {
            fact = String(fact.prefix(197)) + "..."
        }

        if MemoryStore.contains(fact, scope: .user) {
            return ToolOutput(content: "Already remembered.")
        }
        MemoryStore.add(fact, source: .remember, scope: .user)
        return ToolOutput(content: "Remembered.")
    }
}
