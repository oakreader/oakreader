import Foundation

public enum BuiltInTools {
    public static let readFile = ToolDefinition(
        name: "read_file",
        description: "Read the contents of a file at the given path. Returns the file text (truncated to 100K characters if very large).",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute path to the file to read."
                ] as [String: Any]
            ] as [String: Any],
            "required": ["path"]
        ]
    )

    public static let writeFile = ToolDefinition(
        name: "write_file",
        description: "Write content to a file at the given path. Creates parent directories if needed. Overwrites the file if it already exists.",
        inputSchema: [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute path to the file to write."
                ] as [String: Any],
                "content": [
                    "type": "string",
                    "description": "The text content to write to the file."
                ] as [String: Any]
            ] as [String: Any],
            "required": ["path", "content"]
        ]
    )

    public static let all: [ToolDefinition] = [readFile, writeFile]
}
