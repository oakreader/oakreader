import Foundation

/// File search by glob pattern using find.
public struct FindTool: AgentTool {
    public let name = "find"
    public let description = "Search for files by name pattern using glob matching. Returns matching file paths."

    public var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "pattern": [
                    "type": "string",
                    "description": "Glob pattern to match file names (e.g. '*.swift', 'Package.swift')."
                ] as [String: Any],
                "path": [
                    "type": "string",
                    "description": "Directory to search in. Defaults to working directory."
                ] as [String: Any],
            ] as [String: Any],
            "required": ["pattern"]
        ]
    }

    public init() {}

    public func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let pattern = input["pattern"] else {
            return .error("Missing required parameter: pattern")
        }

        let searchPath: String
        if let rawPath = input["path"] {
            searchPath = PathSandbox.resolve(path: rawPath, workingDirectory: context.workingDirectory)
        } else {
            searchPath = context.workingDirectory.path
        }

        let command = "find \(shellQuote(searchPath)) -name \(shellQuote(pattern)) -not -path '*/.*' 2>/dev/null | head -200"

        do {
            let result = try await context.bashOperations.execute(
                command: command,
                workingDirectory: context.workingDirectory,
                timeout: 30
            )

            var output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if output.isEmpty {
                return .success("No files found matching pattern: \(pattern)")
            }

            output = OutputTruncation.truncate(output, maxLength: 100_000)
            return .success(output)
        } catch {
            return .error("Failed to execute find: \(error.localizedDescription)")
        }
    }

}
