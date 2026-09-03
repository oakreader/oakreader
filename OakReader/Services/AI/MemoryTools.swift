import Foundation
import OakAgent

// MARK: - Manage Memory Tool
//
// ChatGPT `bio`-style memory. There is ONE global store — durable facts about the
// user — and the model writes to it inline, during the conversation, two ways:
//
//   1. Proactively, when the user shares something lasting and useful about
//      themselves (their background, goals, what they're studying, durable
//      preferences for how they want answers).
//   2. On explicit request ("remember that …", "forget …", "what do you remember?").
//
// All operations read/write the same `MemoryStore` the manager UI uses, so the
// facts and audit trail stay one coherent set.

/// View or change what the agent remembers about the user.
struct MemoryTool: AgentTool {
    let name = "manage_memory"
    let description = """
        Save and manage durable facts about the USER in your long-term memory — \
        one global profile that is available in every future conversation. \
        Save a fact when the user shares something lasting and useful about \
        themselves (their background, what they're trying to learn or do, durable \
        preferences for how they want you to respond), and also whenever they \
        explicitly ask you to ("remember that …", "forget …"). \
        Do NOT save transient, document-specific, or trivially-derivable details. \
        Operations:
        - list: show current memories (each with an id). Use before update/remove, \
          or to answer "what do you remember about me?".
        - add: save a new durable fact. Check it isn't already covered first.
        - update: replace a fact's text (needs its id from list) — prefer this over \
          adding a near-duplicate.
        - remove: delete a fact (needs its id), e.g. when the user asks to forget it \
          or it's no longer true.
        When the user explicitly asked, briefly confirm what you saved, updated, or \
        removed. When saving proactively on your own, do it silently — don't \
        announce it.
        """

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "operation": [
                    "type": "string",
                    "enum": ["list", "add", "update", "remove"],
                    "description": "What to do."
                ],
                "text": [
                    "type": "string",
                    "description": "Fact text — required for add and update."
                ],
                "id": [
                    "type": "string",
                    "description": "Target fact id from list — required for update and remove."
                ]
            ],
            "required": ["operation"]
        ]
    }

    // A write tool so changes route through the confirmation bar in smart/restricted
    // permission modes. (`list` then also confirms, which is a minor, acceptable cost.)
    var category: ToolCategory { .write }

    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolOutput {
        let operation = (input["operation"] ?? "").lowercased()

        switch operation {
        case "list":
            let facts = MemoryStore.load()
            guard !facts.isEmpty else {
                return ToolOutput(content: "No memories yet.")
            }
            let lines = facts.map { "[\($0.id)] \($0.text)" }
            return ToolOutput(content: "Current memory:\n" + lines.joined(separator: "\n"))

        case "add":
            guard var text = input["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ToolOutput(content: "Error: 'text' is required for add.")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 240 { text = String(text.prefix(237)) + "..." }
            if MemoryStore.contains(text) {
                return ToolOutput(content: "That's already saved.")
            }
            MemoryStore.add(text, source: .remember)
            return ToolOutput(content: "Saved to memory: \"\(text)\".")

        case "update":
            guard let id = input["id"], !id.isEmpty else {
                return ToolOutput(content: "Error: 'id' is required for update — call list first.")
            }
            guard var text = input["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ToolOutput(content: "Error: 'text' is required for update.")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard MemoryStore.load().contains(where: { $0.id == id }) else {
                return ToolOutput(content: "Error: no memory with id \"\(id)\" — call list for current ids.")
            }
            MemoryStore.update(id: id, text: text)
            return ToolOutput(content: "Updated to: \"\(text)\".")

        case "remove":
            guard let id = input["id"], !id.isEmpty else {
                return ToolOutput(content: "Error: 'id' is required for remove — call list first.")
            }
            guard let removed = MemoryStore.load().first(where: { $0.id == id }) else {
                return ToolOutput(content: "Error: no memory with id \"\(id)\" — call list for current ids.")
            }
            MemoryStore.delete(id: id)
            return ToolOutput(content: "Removed: \"\(removed.text)\".")

        default:
            return ToolOutput(content: "Error: operation must be one of list, add, update, remove.")
        }
    }
}
