import Foundation

/// Precise string replacement within a file.
public struct EditTool: AgentTool {
    public let name = "edit"
    public let category: ToolCategory = .write
    public let description = "Perform an exact string replacement in a file. Provide the old string to find and the new string to replace it with. The old_string must match exactly one location in the file."

    public var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute or relative path to the file to edit."
                ] as [String: Any],
                "old_string": [
                    "type": "string",
                    "description": "The exact string to find in the file. Must be unique within the file."
                ] as [String: Any],
                "new_string": [
                    "type": "string",
                    "description": "The replacement string."
                ] as [String: Any],
            ] as [String: Any],
            "required": ["path", "old_string", "new_string"]
        ]
    }

    public init() {}

    public func execute(input: [String: String], context: ToolExecutionContext) async throws -> ToolOutput {
        guard let rawPath = input["path"] else {
            return .error("Missing required parameter: path")
        }
        guard let oldString = input["old_string"] else {
            return .error("Missing required parameter: old_string")
        }
        guard let newString = input["new_string"] else {
            return .error("Missing required parameter: new_string")
        }

        let resolvedPath = PathSandbox.resolve(path: rawPath, workingDirectory: context.workingDirectory)
        guard let url = PathSandbox.validate(path: resolvedPath, allowedPaths: context.allowedPaths) else {
            return .error("Access denied: path is outside allowed directories")
        }

        do {
            let content = try context.fileOperations.readFile(at: url)

            let occurrences = content.components(separatedBy: oldString).count - 1
            if occurrences == 0 {
                return .error("old_string not found in file. Make sure it matches exactly, including whitespace and indentation.")
            }
            if occurrences > 1 {
                return .error("old_string found \(occurrences) times. It must be unique. Add more surrounding context to make it unique.")
            }

            let newContent = content.replacingOccurrences(of: oldString, with: newString)
            try context.fileOperations.writeFile(content: newContent, to: url)

            return .success("Successfully edited \(resolvedPath)")
        } catch {
            return .error("Failed to edit file: \(error.localizedDescription)")
        }
    }
}
