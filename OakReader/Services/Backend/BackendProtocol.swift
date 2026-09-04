import Foundation

/// Swift mirror of the sidecar protocol v2 (web/backend/src/protocol.ts —
/// keep the two in sync). JSONL over stdio, LF-delimited.
///
/// v2: the backend owns the provider catalog, credentials, OAuth, endpoint
/// overrides, and the agentic chat loop. Swift sends provider/model ids and
/// executes tools when the backend asks (`tool_exec` → `tool_result`).
enum BackendProtocol {
    static let version = 2
}

// MARK: - Wire messages (Turn history → backend)

enum WirePart: Encodable {
    case text(String)
    case image(data: String, mimeType: String)

    private enum CodingKeys: String, CodingKey { case type, text, data, mimeType }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        }
    }
}

struct WireToolCall: Encodable {
    var id: String
    var name: String
    var args: AnyJSONObject
}

enum WireMessage: Encodable {
    case user(parts: [WirePart])
    case assistant(text: String, thinking: String?, toolCalls: [WireToolCall])
    case toolResult(callId: String, name: String, content: String, isError: Bool)

    private enum CodingKeys: String, CodingKey {
        case role, parts, text, thinking, toolCalls, callId, name, content, isError
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user(let parts):
            try container.encode("user", forKey: .role)
            try container.encode(parts, forKey: .parts)
        case .assistant(let text, let thinking, let toolCalls):
            try container.encode("assistant", forKey: .role)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(thinking, forKey: .thinking)
            try container.encode(toolCalls, forKey: .toolCalls)
        case .toolResult(let callId, let name, let content, let isError):
            try container.encode("toolResult", forKey: .role)
            try container.encode(callId, forKey: .callId)
            try container.encode(name, forKey: .name)
            try container.encode(content, forKey: .content)
            try container.encode(isError, forKey: .isError)
        }
    }
}

struct WireToolDef: Encodable {
    var name: String
    var description: String
    var inputSchema: AnyJSONObject
}

/// Encodes an arbitrary `[String: Any]` JSON object (tool schemas / arguments).
struct AnyJSONObject: Encodable {
    var object: [String: Any]

    init(_ object: [String: Any]) { self.object = object }

    func encode(to encoder: Encoder) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(JSONFragment.self, from: data)
        try decoded.encode(to: encoder)
    }
}

/// Codable passthrough for arbitrary JSON.
indirect enum JSONFragment: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONFragment])
    case object([String: JSONFragment])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONFragment].self) { self = .array(a) }
        else { self = .object(try container.decode([String: JSONFragment].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) as Any : n
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }
}

// MARK: - Commands

struct BackendCommand: Encodable {
    var id: String
    var type: String
    var providerId: String?
    var model: String?
    var system: String?
    var messages: [WireMessage]?
    var tools: [WireToolDef]?
    var maxTokens: Int?
    var reasoning: String?
    var maxIterations: Int?
    var apiKey: String?
    var baseUrl: String?
    var key: String?
    var callId: String?
    var content: String?
    var isError: Bool?
    var promptId: String?
    var value: String?
}

// MARK: - Events

struct BackendEvent: Decodable {
    var id: String
    var type: String  // response | delta | thinking | tool_exec | assistant | oauth_notify | oauth_prompt | done | error

    // response
    var command: String?
    var success: Bool?
    var `protocol`: Int?
    var backend: String?
    var message: String?
    var providers: [BackendProviderSummary]?
    var apiKey: String?

    // delta / thinking
    var text: String?

    // tool_exec
    var callId: String?
    var name: String?
    var args: [String: JSONFragment]?

    // assistant
    var thinking: String?
    var toolCalls: [BackendToolCall]?

    // oauth
    var kind: String?
    var url: String?
    var userCode: String?
    var verificationUri: String?
    var promptId: String?
    var promptType: String?
    var placeholder: String?
    var options: [BackendPromptOption]?

    // done
    var stopReason: String?
}

struct BackendToolCall: Decodable {
    var id: String
    var name: String
    var args: [String: JSONFragment]
}

struct BackendPromptOption: Decodable, Identifiable {
    var id: String
    var label: String
}

// MARK: - Provider catalog payloads

struct BackendModelSummary: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var reasoning: Bool
    var contextWindow: Int
    var maxTokens: Int
    var vision: Bool
}

struct BackendProviderAuth: Decodable, Hashable {
    var kind: String  // "api-key" | "oauth" | "none"
    var oauthAvailable: Bool
    var configured: Bool
    var source: String?
}

struct BackendProviderSummary: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var models: [BackendModelSummary]
    var defaultModel: String?
    var auth: BackendProviderAuth
    var isLocal: Bool
    var baseUrlOverride: String?
    var localUrl: String?
}
