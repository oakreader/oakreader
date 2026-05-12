import Foundation

/// Context passed to each tool's ``AgentTool/execute(input:context:)`` method.
public struct ToolExecutionContext: Sendable {
    /// Current working directory for relative path resolution.
    public let workingDirectory: URL

    /// Path sandbox — tool should validate paths against these allowed roots.
    public let allowedPaths: [URL]

    /// Operations backends (pluggable for testing).
    public let fileOperations: FileOperations
    public let bashOperations: BashOperations
    public let lsOperations: LsOperations

    public init(
        workingDirectory: URL,
        allowedPaths: [URL] = [],
        fileOperations: FileOperations = LocalFileOperations(),
        bashOperations: BashOperations = LocalBashOperations(),
        lsOperations: LsOperations = LocalLsOperations()
    ) {
        self.workingDirectory = workingDirectory
        self.allowedPaths = allowedPaths
        self.fileOperations = fileOperations
        self.bashOperations = bashOperations
        self.lsOperations = lsOperations
    }
}
