import Foundation

/// Factory for creating sets of agent tools.
public enum ToolKit {
    /// All 7 built-in tools.
    public static func allTools() -> [any AgentTool] {
        [
            ReadTool(),
            WriteTool(),
            EditTool(),
            BashTool(),
            GrepTool(),
            FindTool(),
            LsTool(),
        ]
    }

    /// Read-only tools (no writes, no shell).
    public static func readOnlyTools() -> [any AgentTool] {
        [
            ReadTool(),
            GrepTool(),
            FindTool(),
            LsTool(),
        ]
    }

    /// Coding-focused tools (read, write, edit, bash).
    public static func codingTools() -> [any AgentTool] {
        [
            ReadTool(),
            WriteTool(),
            EditTool(),
            BashTool(),
        ]
    }

    /// Convert an array of ``AgentTool`` to ``ToolDefinition`` for sending to an LLM.
    public static func definitions(from tools: [any AgentTool]) -> [ToolDefinition] {
        tools.map { $0.definition }
    }
}
