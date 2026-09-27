import Foundation

/// Protocol for subprocess execution (pluggable for testing).
protocol BashOperations: Sendable {
    /// Run an executable directly with an argument vector. Arguments are passed
    /// literally to the process — no shell is involved — so they are immune to
    /// shell injection and quoting issues.
    func execute(
        executable: String, arguments: [String], workingDirectory: URL, timeout: TimeInterval
    ) async throws -> BashResult
}

extension BashOperations {
    /// Convenience: run a command string through `/bin/bash -c`. Subject to shell
    /// parsing — only use with trusted/escaped input.
    func execute(command: String, workingDirectory: URL, timeout: TimeInterval) async throws -> BashResult {
        try await execute(
            executable: "/bin/bash", arguments: ["-c", command],
            workingDirectory: workingDirectory, timeout: timeout
        )
    }
}

/// Result of a shell command execution.
struct BashResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    /// Combined output (stdout + stderr) for display.
    var combinedOutput: String {
        var parts: [String] = []
        if !stdout.isEmpty { parts.append(stdout) }
        if !stderr.isEmpty { parts.append(stderr) }
        return parts.joined(separator: "\n")
    }
}

/// Default local shell implementation using Process.
struct LocalBashOperations: BashOperations, Sendable {
    init() {}

    func execute(
        executable: String, arguments: [String], workingDirectory: URL, timeout: TimeInterval
    ) async throws -> BashResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Timeout handling
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning {
                process.terminate()
            }
        }

        process.waitUntilExit()
        timeoutTask.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return BashResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }
}
