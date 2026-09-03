import Foundation
import OakAI

/// Swift mirror of the sidecar protocol v1 (web/backend/src/protocol.ts —
/// keep the two in sync). JSONL over stdio, LF-delimited.
enum BackendProtocol {
    static let version = 1
}

/// pi-ai api ids, 1:1 with OakAI's `APIFormat`.
enum BackendAPI: String, Encodable {
    case anthropicMessages = "anthropic-messages"
    case openaiCompletions = "openai-completions"
    case openaiResponses = "openai-responses"
    case googleGenerativeAI = "google-generative-ai"

    init(_ format: APIFormat) {
        switch format {
        case .anthropicMessages: self = .anthropicMessages
        case .openaiCompletions: self = .openaiCompletions
        case .openaiResponses: self = .openaiResponses
        case .googleGenerativeAI: self = .googleGenerativeAI
        }
    }

    /// OakAI's `ProviderInfo.baseURL` stores the full request endpoint; pi-ai
    /// wants the API base and appends the path itself. Strip this format's suffix.
    func apiBase(fromEndpoint endpoint: URL) -> String {
        var s = endpoint.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        let suffix: String
        switch self {
        case .anthropicMessages: suffix = "/messages"
        case .openaiCompletions: suffix = "/chat/completions"
        case .openaiResponses: suffix = "/responses"
        case .googleGenerativeAI: suffix = "/models"
        }
        if s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        return s
    }
}

struct BackendModelSpec: Encodable {
    var api: BackendAPI
    var baseUrl: String
    var id: String
    var headers: [String: String]?
}

struct BackendCompleteCommand: Encodable {
    var id: String
    var type = "complete"
    var model: BackendModelSpec
    var auth: Auth
    var system: String?
    var messages: [Message]
    var maxTokens: Int

    struct Auth: Encodable { var apiKey: String? }
    struct Message: Encodable {
        var role: String
        var content: String
    }
}

struct BackendSimpleCommand: Encodable {
    var id: String
    var type: String  // "ping" | "abort"
}

/// Every server→client event shape, flattened; `type` discriminates.
struct BackendEvent: Decodable {
    var id: String
    var type: String  // response | delta | done | error
    var text: String?
    var stopReason: String?
    var message: String?
    var success: Bool?
    var `protocol`: Int?
    var backend: String?
}
