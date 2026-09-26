import Foundation

/// One JSON-RPC 2.0 envelope, in either direction.
///
/// The spec's shapes overlap enough that a single permissive struct decodes
/// all four (request, response, error response, notification) and `kind`
/// classifies it. That is simpler than four types and a discriminator, because
/// the discriminator is "which fields are present".
struct RPCEnvelope: Codable {
    var jsonrpc: String = "2.0"
    /// Absent on notifications, by definition.
    var id: String?
    /// Absent on responses.
    var method: String?
    var params: JSONFragment?
    var result: JSONFragment?
    var error: RPCErrorObject?

    enum Kind {
        case request(id: String, method: String)
        case notification(method: String)
        case response(id: String)
        case failure(id: String, error: RPCErrorObject)
        /// Neither a valid request nor a valid response.
        case malformed
    }

    var kind: Kind {
        if let method {
            if let id { return .request(id: id, method: method) }
            return .notification(method: method)
        }
        guard let id else { return .malformed }
        if let error { return .failure(id: id, error: error) }
        return .response(id: id)
    }

    static func request(id: String, method: String, params: JSONFragment?) -> RPCEnvelope {
        RPCEnvelope(id: id, method: method, params: params)
    }
    static func notification(method: String, params: JSONFragment?) -> RPCEnvelope {
        RPCEnvelope(method: method, params: params)
    }
    static func response(id: String, result: JSONFragment?) -> RPCEnvelope {
        RPCEnvelope(id: id, result: result ?? .object([:]))
    }
    static func failure(id: String, code: Int, message: String) -> RPCEnvelope {
        RPCEnvelope(id: id, error: RPCErrorObject(code: code, message: message))
    }
}

/// The spec's error object. `data` carries whatever the code implies — a
/// retryAfter for rate limits, a provider id for auth failures.
struct RPCErrorObject: Codable, Error {
    var code: Int
    var message: String
    var data: JSONFragment?
}

extension RPCErrorObject: LocalizedError {
    var errorDescription: String? { message }

    /// True when re-authenticating is the useful next step, rather than retrying.
    var isAuthFailure: Bool { code == RPC.ErrorCode.providerAuth }
    /// True when the same request may succeed later, unchanged.
    var isRetryable: Bool {
        code == RPC.ErrorCode.providerRateLimit || code == RPC.ErrorCode.providerUnavailable
    }
    var retryAfterSeconds: Int? {
        guard case .object(let fields)? = data, case .number(let n)? = fields["retryAfter"] else { return nil }
        return Int(n)
    }
}

/// What a streaming call yields. The stream finishes when the response to the
/// originating request lands, and throws when that response is an error.
///
/// `.request` carries a reverse call scoped to this stream — the sidecar asking
/// the shell to run a tool, or to prompt the user, as part of *this* request.
/// Routing it here rather than to a global handler keeps the caller's context
/// (which tools are registered, which confirmation UI is up) exactly where it
/// already lives. The consumer must answer with `respond` or `respondError`.
enum RPCStreamEvent {
    case notification(method: String, params: JSONFragment?)
    case request(id: String, method: String, params: JSONFragment?)
}

/// Encoding helpers so call sites hand over typed params and get typed results.
enum RPCCoding {
    static func fragment<T: Encodable>(_ value: T) throws -> JSONFragment {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONFragment.self, from: data)
    }

    static func decode<T: Decodable>(_ type: T.Type, from fragment: JSONFragment?) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: (fragment ?? .object([:])).anyValue)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Result type for requests whose success is the absence of an error.
struct RPCEmpty: Decodable {}
