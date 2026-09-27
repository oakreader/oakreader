import Foundation

/// Where a tool call is allowed to act.
///
/// Both fields exist for the tools the core runs: they travel with a
/// `tools/run` call so the sandbox is enforced where the file is opened, not
/// where the request was made. The shell's own tools read app state and ignore
/// them.
struct ToolExecutionContext: Sendable {
    /// Resolves a relative path, and where a command runs.
    let workingDirectory: URL

    /// Roots a path must sit inside. Empty means unsandboxed.
    let allowedPaths: [URL]

    init(workingDirectory: URL, allowedPaths: [URL] = []) {
        self.workingDirectory = workingDirectory
        self.allowedPaths = allowedPaths
    }
}
