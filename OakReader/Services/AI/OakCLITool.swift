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
        items list [--collection <name>] [--tag <name>] [--search <q>] [--sort title|author|date] [--limit N] | \
        items show <item> | items read <item> [--pages 1-5] | \
        tags list | tags create <name> | tags add <tag> <item> | \
        search <query> [--limit N] | status <item> [unread|reading|completed|archived]. \
        Output is always JSON. \
        IMPORTANT: Always use --limit (e.g. --limit 20) with "items list" and "search" to avoid overwhelming output. \
        Only omit --limit when the user explicitly asks to see everything.
        """

    private static let oakPath = "/usr/local/bin/oak"

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "description":
                        "The oak subcommand and arguments (e.g. \"collections list\", \"tags list\", \"items list --limit 10\", \"items list --collection Papers --limit 20\", \"search attention mechanism --limit 10\")."
                ] as [String: Any]
            ] as [String: Any],
            "required": ["command"]
        ]
    }

    /// Maximum output length returned to the agent to avoid context bloat.
    private static let maxOutputLength = 8_000

    func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let command = input["command"], !command.isEmpty else {
            return .error("Missing required parameter: command")
        }

        // Safety net: inject --limit 20 for list/search commands that omit it
        var safeCommand = command
        if !safeCommand.contains("--limit") {
            let listPattern = safeCommand.hasPrefix("items list") || safeCommand.hasPrefix("search")
            if listPattern {
                safeCommand += " --limit 20"
            }
        }

        // Build the full shell command — always append --json for structured output
        let hasJsonFlag = safeCommand.contains("--json")
        let fullCommand = hasJsonFlag
            ? "\(Self.oakPath) \(safeCommand)"
            : "\(Self.oakPath) \(safeCommand) --json"

        do {
            let result = try await context.bashOperations.execute(
                command: fullCommand,
                workingDirectory: context.workingDirectory,
                timeout: 30
            )

            var output = result.combinedOutput
            output = OutputTruncation.truncate(output, maxLength: Self.maxOutputLength)

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
