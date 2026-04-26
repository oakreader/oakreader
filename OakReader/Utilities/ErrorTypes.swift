import Foundation

enum OakReaderError: LocalizedError {
    case fileNotFound(URL)
    case fileReadFailed(URL, underlying: Error?)
    case fileWriteFailed(URL, underlying: Error?)
    case invalidPDF
    case passwordRequired
    case incorrectPassword
    case encryptionFailed(String)
    case pageOutOfRange(index: Int, count: Int)
    case conversionFailed(format: String, underlying: Error?)
    case compressionFailed(underlying: Error?)
    case comparisonFailed(String)
    case redactionFailed(String)
    case signatureFailed(String)
    case certificateNotFound
    case formFieldError(String)
    case mergeError(String)
    case splitError(String)
    case batchError(String, fileURL: URL?)
    case exportFailed(String)
    case importFailed(String)
    case watermarkFailed(String)
    case accessibilityError(String)
    case cancelled
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .fileReadFailed(let url, let underlying):
            return "Failed to read \(url.lastPathComponent): \(underlying?.localizedDescription ?? "unknown error")"
        case .fileWriteFailed(let url, let underlying):
            return "Failed to write \(url.lastPathComponent): \(underlying?.localizedDescription ?? "unknown error")"
        case .invalidPDF:
            return "The file is not a valid PDF document."
        case .passwordRequired:
            return "This document requires a password."
        case .incorrectPassword:
            return "The password is incorrect."
        case .encryptionFailed(let reason):
            return "Encryption failed: \(reason)"
        case .pageOutOfRange(let index, let count):
            return "Page \(index + 1) is out of range. Document has \(count) pages."
        case .conversionFailed(let format, let underlying):
            return "Conversion to \(format) failed: \(underlying?.localizedDescription ?? "unknown error")"
        case .compressionFailed(let underlying):
            return "Compression failed: \(underlying?.localizedDescription ?? "unknown error")"
        case .comparisonFailed(let reason):
            return "Comparison failed: \(reason)"
        case .redactionFailed(let reason):
            return "Redaction failed: \(reason)"
        case .signatureFailed(let reason):
            return "Signature failed: \(reason)"
        case .certificateNotFound:
            return "No signing certificate found in Keychain."
        case .formFieldError(let reason):
            return "Form field error: \(reason)"
        case .mergeError(let reason):
            return "Merge failed: \(reason)"
        case .splitError(let reason):
            return "Split failed: \(reason)"
        case .batchError(let reason, let url):
            let file = url?.lastPathComponent ?? "unknown"
            return "Batch processing error (\(file)): \(reason)"
        case .exportFailed(let reason):
            return "Export failed: \(reason)"
        case .importFailed(let reason):
            return "Import failed: \(reason)"
        case .watermarkFailed(let reason):
            return "Watermark failed: \(reason)"
        case .accessibilityError(let reason):
            return "Accessibility error: \(reason)"
        case .cancelled:
            return "Operation was cancelled."
        case .unknown(let reason):
            return reason
        }
    }
}
