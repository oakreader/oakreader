import Foundation

/// Shell command execution with configurable timeout.
public struct BashTool: AgentTool {
    public let name = "bash"
    public let category: ToolCategory = .dangerous
    public let description = "Execute a bash command. The command runs in the working directory. Use this for git operations, running tests, installing packages, and other terminal tasks."

    public var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "command": [
                    "type": "string",
                    "description": "The bash command to execute."
                ] as [String: Any],
                "timeout": [
                    "type": "string",
                    "description": "Timeout in seconds (default: 120)."
                ] as [String: Any],
            ] as [String: Any],
            "required": ["command"]
        ]
    }

    public init() {}

    public func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let command = input["command"] else {
            return .error("Missing required parameter: command")
        }

        let timeout = TimeInterval(input["timeout"] ?? "120") ?? 120

        do {
            let result = try await context.bashOperations.execute(
                command: command,
                workingDirectory: context.workingDirectory,
                timeout: timeout
            )

            var output = result.combinedOutput
            output = OutputTruncation.truncate(output, maxLength: 100_000)

            if result.exitCode != 0 {
                return ToolOutput(
                    content: "Exit code: \(result.exitCode)\n\(output)",
                    isError: true
                )
            }

            return .success(output)
        } catch {
            return .error("Failed to execute command: \(error.localizedDescription)")
        }
    }
}
