import Foundation

/// Errors that can occur during agent execution.
public enum AgentError: LocalizedError, Sendable {
    case noProvider
    case maxIterationsExceeded(Int)
    case toolNotFound(String)
    case toolExecutionFailed(String, Error)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noProvider:
            return "No LLM provider configured."
        case .maxIterationsExceeded(let count):
            return "Agent exceeded maximum iterations (\(count))."
        case .toolNotFound(let name):
            return "Unknown tool: \(name)"
        case .toolExecutionFailed(let name, let error):
            return "Tool '\(name)' failed: \(error.localizedDescription)"
        case .cancelled:
            return "Agent run was cancelled."
        }
    }
}
