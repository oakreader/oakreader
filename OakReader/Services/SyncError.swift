import Foundation

/// Shared error type for X Bookmarks and GitHub Stars sync operations.
enum SyncError: LocalizedError {
    case tokenNotConfigured
    case authenticationFailed
    case apiFailed(statusCode: Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .tokenNotConfigured:
            return "API token is not configured."
        case .authenticationFailed:
            return "Authentication failed. Please check your token."
        case .apiFailed(let statusCode):
            return "API request failed with status code \(statusCode)."
        case .emptyResponse:
            return "The API returned an empty response."
        }
    }
}
