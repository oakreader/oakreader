import Foundation
import OakAgent

// MARK: - Manage Memory Tool
//
// The explicit, user-initiated memory lane. There are exactly two ways memory is
// written:
//
//   1. PASSIVE / implicit — the agent merely *observes* a durable fact in passing.
//      Handled entirely in the background by `MemoryReflectionService` ("dreaming").
//      The model never touches memory for this on the hot path.
//   2. EXPLICIT / user-directed — the user literally asks the agent to view, add,
//      change, or forget something ("remember that …", "add … to my memory",
//      "what do you remember about me?", "forget …"). THAT is what this tool is for.
//
// Splitting by *initiator* (agent-observed vs user-commanded) is the whole point:
// the model is told to use this tool ONLY on explicit request, so it isn't making a
// save/no-save decision every turn — it just fulfils a direct instruction and
// confirms it conversationally.
//
// All operations read/write the same `MemoryStore` the background lane and the
// manager UI use, so everything stays one coherent set of facts + audit trail.

/// View or change the user's memory, only when they explicitly ask.
struct MemoryTool: AgentTool {
    /// The item the current chat is about, if any — enables item-scoped memory.
    let itemId: String?

    let name = "manage_memory"
    let description = """
        View or change what you remember about the user — use ONLY when the user \
        explicitly asks you to (e.g. "remember that …", "add … to my memory", \
        "what do you remember about me?", "update …", "forget …"). \
        Do NOT use this to passively save things you merely noticed — that happens \
        automatically in the background. Operations:
        - list: show current memories (each with an id). Use before update/remove, \
          or to answer "what do you remember?".
        - add: save a new fact the user asked you to remember.
        - update: replace a fact's text (needs its id from list).
        - remove: delete a fact the user asked you to forget (needs its id).
        Scope defaults to the user's global memory; pass scope "item" to attach a \
        note to the document currently open. After any change, briefly tell the user \
        what you saved, updated, or removed.
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
                "scope": [
                    "type": "string",
                    "enum": ["user", "item"],
                    "description": "user = global profile (default); item = the document currently open."
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

        // Resolve scope. "item" requires an open document.
        let scope: MemoryScope
        if (input["scope"] ?? "user").lowercased() == "item" {
            guard let itemId else {
                return ToolOutput(content: "Error: no document is open, so item memory isn't available. Use scope \"user\".")
            }
            scope = .item(itemId)
        } else {
            scope = .user
        }
        let scopeName = scope == .user ? "your" : "this document's"

        switch operation {
        case "list":
            let facts = MemoryStore.load(scope)
            guard !facts.isEmpty else {
                return ToolOutput(content: "No \(scopeName) memories yet.")
            }
            let lines = facts.map { "[\($0.id)]\($0.pinned ? " 📌" : "") \($0.text)" }
            return ToolOutput(content: "Current \(scopeName) memory:\n" + lines.joined(separator: "\n"))

        case "add":
            guard var text = input["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ToolOutput(content: "Error: 'text' is required for add.")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > 240 { text = String(text.prefix(237)) + "..." }
            if MemoryStore.contains(text, scope: scope) {
                return ToolOutput(content: "That's already saved.")
            }
            MemoryStore.add(text, source: .remember, scope: scope)
            return ToolOutput(content: "Saved to \(scopeName) memory: \"\(text)\".")

        case "update":
            guard let id = input["id"], !id.isEmpty else {
                return ToolOutput(content: "Error: 'id' is required for update — call list first.")
            }
            guard var text = input["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ToolOutput(content: "Error: 'text' is required for update.")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard MemoryStore.load(scope).contains(where: { $0.id == id }) else {
                return ToolOutput(content: "Error: no memory with id \"\(id)\" — call list for current ids.")
            }
            MemoryStore.update(id: id, text: text, scope: scope)
            return ToolOutput(content: "Updated to: \"\(text)\".")

        case "remove":
            guard let id = input["id"], !id.isEmpty else {
                return ToolOutput(content: "Error: 'id' is required for remove — call list first.")
            }
            guard let removed = MemoryStore.load(scope).first(where: { $0.id == id }) else {
                return ToolOutput(content: "Error: no memory with id \"\(id)\" — call list for current ids.")
            }
            MemoryStore.delete(id: id, scope: scope)
            return ToolOutput(content: "Removed: \"\(removed.text)\".")

        default:
            return ToolOutput(content: "Error: operation must be one of list, add, update, remove.")
        }
    }
}
