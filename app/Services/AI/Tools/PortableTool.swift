import Foundation

/// A tool the core implements, run through the protocol.
///
/// `bash`, `read` and `write` touch the filesystem rather than the app, so
/// nothing about them is macOS and they moved to the portable side with the
/// rest of the agent. What stayed here is the decision: this process receives
/// the model's call, shows it, asks the user when the permission level says to,
/// and only then asks for it to be run.
///
/// That ordering is the point. The alternative — the core executing and merely
/// asking permission first — puts the approving side and the executing side on
/// opposite ends of a pipe, which is one dropped message away from running a
/// command nobody approved.
struct PortableTool: AgentTool {
    let name: String
    let description: String
    let category: ToolCategory
    let inputSchema: [String: Any]

    init?(_ definition: BackendToolDefinition) {
        guard let category = ToolCategory(rawValue: definition.category) else { return nil }
        self.name = definition.name
        self.description = definition.description
        self.category = category
        // The schema is the core's, handed to the model unchanged.
        self.inputSchema = (definition.inputSchema.anyValue as? [String: Any]) ?? [:]
    }

    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolOutput {
        let result = await ToolCatalog.run(
            name: name,
            args: input.stringValues,
            workingDirectory: context.workingDirectory.path,
            allowedPaths: context.allowedPaths.map(\.path))
        return ToolOutput(content: result.content, isError: result.isError)
    }
}

/// The core's tools: what they are, and how to run one.
enum ToolCatalog {
    /// Fetched once per chat turn rather than cached: the set is small, and a
    /// stale copy would mean declaring a tool the core no longer has.
    static func list() async -> [PortableTool] {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.toolsList, params: RPC.ToolsListParams(),
                as: RPC.ToolsListResult.self)
            return (result.tools ?? []).compactMap(PortableTool.init)
        } catch {
            Log.error(Log.store, "tools/list failed: \(error.localizedDescription)")
            return []
        }
    }

    static func run(
        name: String, args: [String: String], workingDirectory: String, allowedPaths: [String]
    ) async -> (content: String, isError: Bool) {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.toolsRun,
                params: RPC.ToolsRunParams(
                    name: name,
                    args: AnyJSONObject(args),
                    workingDirectory: workingDirectory,
                    allowedPaths: allowedPaths),
                as: RPC.ToolsRunResult.self)
            return (result.content ?? "", result.isError ?? false)
        } catch {
            // A tool that could not run is a failed tool call, not a failed
            // turn: the model is better told so than left waiting.
            return ("Tool error: \(error.localizedDescription)", true)
        }
    }
}
