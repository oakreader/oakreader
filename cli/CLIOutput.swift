import Foundation

// MARK: - Structured Output Layer

/// Dispatches output in either JSON or human-readable format.
/// JSON mode wraps all output in a standard envelope for AI agent consumption.
struct CLIOutput {
    let json: Bool
    let quiet: Bool

    /// Emit a single successful result.
    func success<T: Encodable>(operation: String, result: T) {
        if json {
            let envelope = SuccessEnvelope(operation: operation, result: result)
            printJSON(envelope)
        }
    }

    /// Emit a list of results with optional metadata.
    func results<T: Encodable>(operation: String, items: [T], meta: [String: Int]? = nil) {
        if json {
            let envelope = ResultsEnvelope(operation: operation, results: items, meta: meta)
            printJSON(envelope)
        }
    }

    /// Emit a human-only message (suppressed in JSON mode).
    func message(_ text: String) {
        guard !json && !quiet else { return }
        print(text)
    }

    /// Emit an error in structured or human-readable format.
    func error(operation: String, message: String, code: String) {
        if json {
            let envelope = ErrorEnvelope(operation: operation, error: .init(message: message, code: code))
            printJSON(envelope)
        } else {
            fputs("Error: \(message)\n", stderr)
        }
    }

    // MARK: - JSON Envelopes

    private struct SuccessEnvelope<T: Encodable>: Encodable {
        let success = true
        let operation: String
        let result: T
    }

    private struct ResultsEnvelope<T: Encodable>: Encodable {
        let success = true
        let operation: String
        let results: [T]
        let meta: [String: Int]?
    }

    private struct ErrorEnvelope: Encodable {
        let success = false
        let operation: String
        let error: ErrorDetail

        struct ErrorDetail: Encodable {
            let message: String
            let code: String
        }
    }

    private func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            fputs("Error: Failed to encode JSON output\n", stderr)
            return
        }
        print(string)
    }
}

// MARK: - Codable Wrappers for Tuple Results

/// A codable representation of an item with its attachments.
struct CLIItemResult: Encodable {
    let item: CLIItem
    let attachments: [CLIAttachment]
}

/// A codable representation of a tag with its item count.
struct CLITagResult: Encodable {
    let tag: CLIPropertyOption
    let count: Int
}

/// A codable representation of a collection with its item count.
struct CLICollectionResult: Encodable {
    let collection: CLICollection
    let count: Int
}

/// A codable representation of item detail.
struct CLIItemDetail: Encodable {
    let item: CLIItem
    let attachments: [CLIAttachment]
    let tags: [CLIPropertyOption]
    let status: CLIPropertyOption?
    let collections: [CLICollection]
}

/// A codable representation of library stats.
struct CLIStats: Encodable {
    let items: Int
    let collections: Int
    let tags: Int
}

/// A codable wrapper for a simple operation result (create, rename, delete, etc.)
struct CLIOperationResult: Encodable {
    let id: String?
    let message: String
}
