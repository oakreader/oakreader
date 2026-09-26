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
        items list [--collection <name>] [--tag <name>] [--search <q>] [--sort title|author|date] | \
        items show <item> | items read <item> [--pages 1-5] | \
        tags list | tags create <name> | tags add <tag> <item> | \
        search <query> [--limit N] | status <item> [unread|reading|completed|archived]. \
        Output is always JSON. The response includes a meta.count field with the total count. \
        For "search", use --limit (max 20) to control result size.
        """

    private static let oakPath = "/usr/local/bin/oak"

    /// The library database the running app uses. The `oak` CLI defaults to
    /// `~/OakReader/library.sqlite`, but Debug builds store data under
    /// `~/OakReader-Dev/`. Without this the agent queries the wrong (empty)
    /// database and reports "0 items, 0 collections, 0 tags".
    private static var databasePath: String {
        CatalogDatabase.dataDirectory.appendingPathComponent("library.sqlite").path
    }

    var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "description":
                        "The oak subcommand and arguments (e.g. \"collections list\", \"tags list\", \"items list\", \"items list --collection Papers\", \"search attention mechanism --limit 10\")."
                ] as [String: Any]
            ] as [String: Any],
            "required": ["command"]
        ]
    }

    /// Maximum output length returned to the agent to avoid context bloat.
    private static let maxOutputLength = 8_000

    func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolOutput {
        guard let command = input["command"], !command.isEmpty else {
            return .error("Missing required parameter: command")
        }

        // Safety net: items list always gets a tight limit (agent reads meta.count
        // for totals); search gets capped.
        var safeCommand = command
        if safeCommand.hasPrefix("items list") {
            // Strip any --limit the agent may have added and force --limit 5
            safeCommand = safeCommand.replacingOccurrences(
                of: #"--limit\s+\d+"#, with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespaces)
            safeCommand += " --limit 5"
        } else if safeCommand.hasPrefix("search") && !safeCommand.contains("--limit") {
            safeCommand += " --limit 20"
        }

        // Tokenize the agent-supplied command into an argument vector and run the
        // binary directly — no shell — so collection/tag/search values containing
        // spaces or shell metacharacters (e.g. "R&D") are passed literally and
        // cannot be misinterpreted or injected.
        var arguments = Self.tokenize(safeCommand)
        guard !arguments.isEmpty else {
            return .error("Missing required parameter: command")
        }
        // `--db` pins the CLI to the same database the app uses (Debug vs Release);
        // it is a global flag valid before the subcommand. Always request JSON.
        arguments.insert(contentsOf: ["--db", Self.databasePath], at: 0)
        if !arguments.contains("--json") {
            arguments.append("--json")
        }

        do {
            let result = try await context.bashOperations.execute(
                executable: Self.oakPath,
                arguments: arguments,
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

    /// Split a command string into argv tokens, honoring single/double quotes and
    /// backslash escapes (POSIX-shell style) so quoted multi-word values stay
    /// intact. The result is passed straight to the process — never re-parsed by a
    /// shell — so the tokens are safe regardless of their contents.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var hasToken = false
        var inSingle = false
        var inDouble = false
        var escaped = false

        for ch in input {
            if escaped {
                current.append(ch); escaped = false; continue
            }
            if inSingle {
                if ch == "'" { inSingle = false } else { current.append(ch) }
                continue
            }
            if ch == "\\" && !inSingle {
                escaped = true; hasToken = true; continue
            }
            if inDouble {
                if ch == "\"" { inDouble = false } else { current.append(ch) }
                continue
            }
            switch ch {
            case "'": inSingle = true; hasToken = true
            case "\"": inDouble = true; hasToken = true
            case " ", "\t", "\n", "\r":
                if hasToken { tokens.append(current); current = ""; hasToken = false }
            default:
                current.append(ch); hasToken = true
            }
        }
        if hasToken { tokens.append(current) }
        return tokens
    }
}
