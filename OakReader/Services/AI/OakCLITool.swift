import Foundation
import OakAgent

/// Executes `oak` CLI commands so the AI agent can list collections, tags,
/// search items, manage the library, and more.  Always appends `--json`
/// for structured output the LLM can parse easily.
struct OakCLITool: AgentTool, Sendable {
    let name = "oak"
    let description = """
        Run an oak CLI command to interact with the user's library. \
        Available commands: \
        collections list | collections create <name> | collections add <collection> <item> | \
        items list [--collection <name>] [--tag <name>] [--search <q>] | items show <item> | \
        tags list | tags create <name> | tags add <tag> <item> | \
        search <query> | status <item> [unread|reading|completed|archived]. \
        Output is always JSON. Use this to discover collections, tags, and manage items.
        """

    private static let oakPath = "/usr/local/bin/oak"

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "description":
                        "The oak subcommand and arguments (e.g. \"collections list\", \"tags list\", \"items list --collection Papers\", \"search attention mechanism\")."
                ] as [String: Any]
            ] as [String: Any],
            "required": ["command"]
        ]
    }

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let command = input["command"], !command.isEmpty else {
            return .error("Missing required parameter: command")
        }

        // Build the full shell command — always append --json for structured output
        let hasJsonFlag = command.contains("--json")
        let fullCommand = hasJsonFlag
            ? "\(Self.oakPath) \(command)"
            : "\(Self.oakPath) \(command) --json"

        do {
            let result = try await context.bashOperations.execute(
                command: fullCommand,
                workingDirectory: context.workingDirectory,
                timeout: 30
            )

            var output = result.combinedOutput
            output = OutputTruncation.truncate(output, maxLength: 50_000)

            if result.exitCode != 0 {
                return ToolOutput(
                    content: "oak command failed (exit \(result.exitCode)):\n\(output)",
                    isError: true
                )
            }

            return .success(output.isEmpty ? "Command completed successfully." : output)
        } catch {
            return .error("Failed to execute oak command: \(error.localizedDescription)")
        }
    }
}
