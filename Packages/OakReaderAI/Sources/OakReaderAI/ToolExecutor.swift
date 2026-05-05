import Foundation

/// Executes tool calls with path sandboxing to restrict file access.
public actor ToolExecutor {
    private let allowedPaths: [URL]
    private static let maxReadLength = 100_000

    public init(allowedPaths: [URL]) {
        self.allowedPaths = allowedPaths
    }

    public func execute(_ toolCall: ToolCall) async -> ToolResult {
        switch toolCall.name {
        case "read_file":
            return await executeReadFile(toolCall)
        case "write_file":
            return await executeWriteFile(toolCall)
        default:
            return ToolResult(
                toolCallId: toolCall.id,
                toolName: toolCall.name,
                content: "Unknown tool: \(toolCall.name)",
                isError: true
            )
        }
    }

    // MARK: - Read File

    private func executeReadFile(_ toolCall: ToolCall) async -> ToolResult {
        guard let path = toolCall.input["path"] else {
            return ToolResult(
                toolCallId: toolCall.id, toolName: toolCall.name,
                content: "Missing required parameter: path", isError: true
            )
        }

        guard let url = validatedURL(for: path) else {
            return ToolResult(
                toolCallId: toolCall.id, toolName: toolCall.name,
                content: "Access denied: path is outside allowed directories", isError: true
            )
        }

        do {
            var content = try String(contentsOf: url, encoding: .utf8)
            if content.count > Self.maxReadLength {
                content = String(content.prefix(Self.maxReadLength))
                    + "\n\n[Truncated at \(Self.maxReadLength) characters]"
            }
            return ToolResult(
                toolCallId: toolCall.id, toolName: toolCall.name,
                content: content
            )
        } catch {
            return ToolResult(
                toolCallId: toolCall.id, toolName: toolCall.name,
                content: "Failed to read file: \(error.localizedDescription)", isError: true
            )
        }
    }

    // MARK: - Write File

    private func executeWriteFile(_ toolCall: ToolCall) async -> ToolResult {
        guard let path = toolCall.input["path"] else {
            return ToolResult(
                toolCallId: toolCall.id, toolName: toolCall.name,
                content: "Missing required parameter: path", isError: true
            )
        }
        guard let content = toolCall.input["content"] else {
            return ToolResult(
                toolCallId: toolCall.id, toolName: toolCall.name,
                content: "Missing required parameter: content", isError: true
            )
        }

        guard let url = validatedURL(for: path) else {
            return ToolResult(
                toolCallId: toolCall.id, toolName: toolCall.name,
                content: "Access denied: path is outside allowed directories", isError: true
            )
        }

        do {
            // Create parent directories if needed
            let parentDir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            try content.write(to: url, atomically: true, encoding: .utf8)
            return ToolResult(
                toolCallId: toolCall.id, toolName: toolCall.name,
                content: "Successfully wrote \(content.count) characters to \(path)"
            )
        } catch {
            return ToolResult(
                toolCallId: toolCall.id, toolName: toolCall.name,
                content: "Failed to write file: \(error.localizedDescription)", isError: true
            )
        }
    }

    // MARK: - Path Validation

    /// Returns a validated, standardized file URL if the path is within allowed directories.
    /// Returns nil if the path escapes the sandbox via `..` or symlinks.
    private func validatedURL(for path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardized

        for allowed in allowedPaths {
            let allowedPath = allowed.standardized.path
            if url.path.hasPrefix(allowedPath) {
                return url
            }
        }
        return nil
    }
}
