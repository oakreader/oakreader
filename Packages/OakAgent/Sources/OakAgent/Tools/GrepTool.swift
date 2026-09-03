import Foundation

/// Content search using grep -rn.
public struct GrepTool: AgentTool {
    public let name = "search_files"
    public let description = "Search for a pattern in files using grep. Returns matching lines with file paths and line numbers."

    public var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "pattern": [
                    "type": "string",
                    "description": "The regex pattern to search for."
                ] as [String: Any],
                "path": [
                    "type": "string",
                    "description": "Directory or file to search in. Defaults to working directory."
                ] as [String: Any],
                "include": [
                    "type": "string",
                    "description": "File glob pattern to include (e.g. '*.swift')."
                ] as [String: Any],
            ] as [String: Any],
            "required": ["pattern"]
        ]
    }

    public init() {}

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolOutput {
        guard let pattern = input["pattern"] else {
            return .error("Missing required parameter: pattern")
        }

        let searchPath: String
        if let rawPath = input["path"] {
            searchPath = PathSandbox.resolve(path: rawPath, workingDirectory: context.workingDirectory)
        } else {
            searchPath = context.workingDirectory.path
        }

        var command = "grep -rn"
        if let include = input["include"] {
            command += " --include='\(include)'"
        }
        command += " -- \(shellQuote(pattern)) \(shellQuote(searchPath))"

        do {
            let result = try await context.bashOperations.execute(
                command: command,
                workingDirectory: context.workingDirectory,
                timeout: 30
            )

            // grep returns exit code 1 for "no matches" — that's not an error
            if result.exitCode > 1 {
                return .error("grep failed: \(result.stderr)")
            }

            var output = result.stdout
            if output.isEmpty {
                return .success("No matches found.")
            }

            output = OutputTruncation.truncate(output, maxLength: 100_000)
            return .success(output)
        } catch {
            return .error("Failed to execute grep: \(error.localizedDescription)")
        }
    }

}
