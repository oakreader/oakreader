import Foundation

/// Read file contents with optional offset/limit and truncation.
public struct ReadTool: AgentTool {
    public let name = "read"
    public let description = "Read the contents of a file at the given path. Optionally specify offset (line number to start from, 1-based) and limit (number of lines to read). Returns the file text with line numbers."

    public var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute or relative path to the file to read."
                ] as [String: Any],
                "offset": [
                    "type": "string",
                    "description": "Line number to start reading from (1-based). Defaults to 1."
                ] as [String: Any],
                "limit": [
                    "type": "string",
                    "description": "Maximum number of lines to read. Defaults to all."
                ] as [String: Any],
            ] as [String: Any],
            "required": ["path"]
        ]
    }

    public init() {}

    public func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let rawPath = input["path"] else {
            return .error("Missing required parameter: path")
        }

        let resolvedPath = PathSandbox.resolve(path: rawPath, workingDirectory: context.workingDirectory)
        guard let url = PathSandbox.validate(path: resolvedPath, allowedPaths: context.allowedPaths) else {
            return .error("Access denied: path is outside allowed directories")
        }

        do {
            let content = try context.fileOperations.readFile(at: url)
            let allLines = content.components(separatedBy: "\n")

            let offset = Int(input["offset"] ?? "1") ?? 1
            let startIndex = max(0, offset - 1) // Convert 1-based to 0-based

            let limit: Int?
            if let limitStr = input["limit"], let l = Int(limitStr) {
                limit = l
            } else {
                limit = nil
            }

            let endIndex: Int
            if let limit {
                endIndex = min(allLines.count, startIndex + limit)
            } else {
                endIndex = allLines.count
            }

            guard startIndex < allLines.count else {
                return .error("Offset \(offset) exceeds file length (\(allLines.count) lines)")
            }

            let selectedLines = allLines[startIndex..<endIndex]
            var result = selectedLines.enumerated().map { idx, line in
                let lineNum = startIndex + idx + 1
                return "\(lineNum)\t\(line)"
            }.joined(separator: "\n")

            // Truncate if needed
            result = OutputTruncation.truncate(result, maxLength: 100_000)

            return .success(result)
        } catch {
            return .error("Failed to read file: \(error.localizedDescription)")
        }
    }
}
