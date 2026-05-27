import Foundation

/// Directory listing tool.
public struct LsTool: AgentTool {
    public let name = "ls"
    public let description = "List the contents of a directory. Returns file and directory names with sizes."

    public var inputSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": [
                    "type": "string",
                    "description": "Absolute or relative path to the directory. Defaults to working directory."
                ] as [String: Any],
            ] as [String: Any],
            "required": [] as [String]
        ]
    }

    public init() {}

    public func execute(input: ToolInput, context: ToolExecutionContext) async throws -> ToolOutput {
        let rawPath = input["path"] ?? context.workingDirectory.path
        let resolvedPath = PathSandbox.resolve(path: rawPath, workingDirectory: context.workingDirectory)

        guard let url = PathSandbox.validate(path: resolvedPath, allowedPaths: context.allowedPaths) else {
            return .error("Access denied: path is outside allowed directories")
        }

        do {
            let entries = try context.lsOperations.listDirectory(at: url)

            if entries.isEmpty {
                return .success("(empty directory)")
            }

            let lines = entries.map { entry in
                let prefix = entry.isDirectory ? "d " : "  "
                let sizeStr: String
                if let size = entry.size, !entry.isDirectory {
                    sizeStr = " (\(formatSize(size)))"
                } else {
                    sizeStr = ""
                }
                return "\(prefix)\(entry.name)\(sizeStr)"
            }

            return .success(lines.joined(separator: "\n"))
        } catch {
            return .error("Failed to list directory: \(error.localizedDescription)")
        }
    }

    private func formatSize(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var size = Double(bytes)
        var unitIndex = 0
        while size >= 1024 && unitIndex < units.count - 1 {
            size /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", size, units[unitIndex])
    }
}
