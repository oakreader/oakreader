import Foundation

/// Write content to a file, creating parent directories if needed.
public struct WriteTool: AgentTool {
    public let name = "write"
    public let description = "Write content to a file at the given path. Creates parent directories if needed. Overwrites the file if it already exists."

    public var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute or relative path to the file to write."
                ] as [String: Any],
                "content": [
                    "type": "string",
                    "description": "The text content to write to the file."
                ] as [String: Any],
            ] as [String: Any],
            "required": ["path", "content"]
        ]
    }

    public init() {}

    public func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let rawPath = input["path"] else {
            return .error("Missing required parameter: path")
        }
        guard let content = input["content"] else {
            return .error("Missing required parameter: content")
        }

        let resolvedPath = PathSandbox.resolve(path: rawPath, workingDirectory: context.workingDirectory)
        guard let url = PathSandbox.validate(path: resolvedPath, allowedPaths: context.allowedPaths) else {
            return .error("Access denied: path is outside allowed directories")
        }

        do {
            try context.fileOperations.writeFile(content: content, to: url)
            return .success("Successfully wrote \(content.count) characters to \(resolvedPath)")
        } catch {
            return .error("Failed to write file: \(error.localizedDescription)")
        }
    }
}
