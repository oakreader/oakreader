import Foundation

// MARK: - Tool Category

/// Safety classification used by the permission system to decide whether a
/// tool invocation requires user confirmation.
enum ToolCategory: String, Codable, Sendable {
    /// Read-only operations (read_document, search, etc.) — safe.
    case readOnly
    /// Write operations (write_file, edit_file).
    case write
    /// Dangerous / destructive operations (bash, shell commands).
    case dangerous
}

/// Protocol for tools that can be executed by the ``Agent``.
protocol AgentTool: Sendable {
    /// Unique tool name (e.g. "read", "bash").
    var name: String { get }

    /// Human-readable description shown to the LLM.
    var description: String { get }

    /// JSON Schema describing the tool's input parameters.
    var inputSchema: [String: Any] { get }

    /// Safety category for the permission system. Defaults to `.readOnly`.
    var category: ToolCategory { get }

    /// Execute the tool with the given context and return a result.
    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolOutput
}

extension AgentTool {
    /// Default category — most tools are read-only.
    var category: ToolCategory { .readOnly }

    /// The category of one specific call.
    ///
    /// A tool whose risk is uniform answers with `category` and never overrides
    /// this. `oak` is the one that must: the same tool lists collections and
    /// creates them, and declaring the whole thing `write` would put a
    /// confirmation in front of every search the agent runs, while declaring it
    /// `readOnly` — which it did — let it mutate the library unasked.
    func category(for input: ToolInput) -> ToolCategory { category }
}
