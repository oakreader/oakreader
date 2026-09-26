import Foundation

/// A structured JSON value, mirroring pi-ai's `Record<string, any>` tool-argument
/// model. Codable is *transparent*: `.string("x")` encodes as `"x"`, `.object`
/// as `{...}`, etc. — so persisted tool inputs stay plain JSON and old records
/// that stored `[String: String]` decode unchanged.
public enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    // MARK: - Bridging to/from Foundation JSON objects

    /// Wrap a Foundation JSON object (`Any` from `JSONSerialization`).
    public init(any value: Any) {
        switch value {
        case let v as String: self = .string(v)
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .int(v)
        case let v as Double: self = .double(v)
        case let v as NSNumber:
            // NSNumber may carry a bool or numeric; disambiguate.
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                self = .bool(v.boolValue)
            } else if v.doubleValue == v.doubleValue.rounded() {
                self = .int(v.intValue)
            } else {
                self = .double(v.doubleValue)
            }
        case let v as [Any]: self = .array(v.map(JSONValue.init(any:)))
        case let v as [String: Any]:
            self = .object(v.mapValues(JSONValue.init(any:)))
        default: self = .null
        }
    }

    /// Convert back to a Foundation JSON object suitable for `JSONSerialization`.
    public var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        case .null: return NSNull()
        }
    }

    /// Scalar rendered as a plain string; objects/arrays as their JSON text.
    /// `nil` only for explicit `null`. Used for back-compat string access.
    public var scalarString: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d):
            return d == d.rounded() ? String(Int(d)) : String(d)
        case .bool(let b): return String(b)
        case .null: return nil
        case .array, .object: return jsonString
        }
    }

    /// Compact JSON-text encoding of this value.
    public var jsonString: String {
        guard JSONSerialization.isValidJSONObject(anyValue) || !(anyValue is NSNull) else {
            return ""
        }
        // For scalars, JSONSerialization needs a top-level container in older OSes;
        // encode via JSONEncoder which handles fragments.
        if let data = try? JSONEncoder().encode(self), let s = String(data: data, encoding: .utf8) {
            return s
        }
        return ""
    }
}
