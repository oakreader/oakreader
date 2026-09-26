import Foundation

enum OakReaderError: LocalizedError {
    case fileNotFound(URL)
    case fileWriteFailed(URL, underlying: Error?)
    case invalidPDF
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .fileWriteFailed(let url, let underlying):
            return "Failed to write \(url.lastPathComponent): \(underlying?.localizedDescription ?? "unknown error")"
        case .invalidPDF:
            return "The file is not a valid PDF document."
        case .serverError(let reason):
            return "Server error: \(reason)"
        }
    }
}
