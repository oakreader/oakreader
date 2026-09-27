import Foundation

/// Context passed to each tool's ``AgentTool/execute(input:context:)`` method.
struct ToolExecutionContext: Sendable {
    /// Current working directory for relative path resolution.
    let workingDirectory: URL

    /// Path sandbox — tool should validate paths against these allowed roots.
    let allowedPaths: [URL]

    /// Operations backends (pluggable for testing).
    let fileOperations: FileOperations
    let bashOperations: BashOperations

    init(
        workingDirectory: URL,
        allowedPaths: [URL] = [],
        fileOperations: FileOperations = LocalFileOperations(),
        bashOperations: BashOperations = LocalBashOperations()
    ) {
        self.workingDirectory = workingDirectory
        self.allowedPaths = allowedPaths
        self.fileOperations = fileOperations
        self.bashOperations = bashOperations
    }
}
