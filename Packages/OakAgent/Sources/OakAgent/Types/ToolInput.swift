import Foundation

/// Structured tool-call arguments, mirroring pi-ai's `arguments: Record<string, any>`.
/// Holds the parsed JSON object so tools can read nested arrays/objects directly
/// (`input.array("cards")`) while scalar params stay ergonomic (`input["query"]`).
public struct ToolInput: Codable, Sendable, Hashable, ExpressibleByDictionaryLiteral {
    public var values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.values = Dictionary(uniqueKeysWithValues: elements)
    }

    /// Build from a raw JSON arguments string (what providers accumulate).
    public init(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { self.values = [:]; return }
        self.values = obj.mapValues(JSONValue.init(any:))
    }

    /// Build from a Foundation JSON object.
    public init(jsonObject: [String: Any]) {
        self.values = jsonObject.mapValues(JSONValue.init(any:))
    }

    // Transparent Codable: encodes/decodes as the bare JSON object.
    public init(from decoder: Decoder) throws {
        self.values = try [String: JSONValue](from: decoder)
    }
    public func encode(to encoder: Encoder) throws {
        try values.encode(to: encoder)
    }

    // MARK: - Access

    public var isEmpty: Bool { values.isEmpty }
    public var keys: Dictionary<String, JSONValue>.Keys { values.keys }

    /// Scalar string access (objects/arrays render as JSON text). `nil` if absent.
    public subscript(_ key: String) -> String? {
        values[key]?.scalarString
    }

    public func value(_ key: String) -> JSONValue? { values[key] }

    public func string(_ key: String) -> String? {
        if case .string(let s)? = values[key] { return s }
        return values[key]?.scalarString
    }

    public func int(_ key: String) -> Int? {
        switch values[key] {
        case .int(let i)?: return i
        case .double(let d)?: return Int(d)
        case .string(let s)?: return Int(s)
        default: return nil
        }
    }

    public func bool(_ key: String) -> Bool? {
        switch values[key] {
        case .bool(let b)?: return b
        case .string(let s)?: return Bool(s)
        default: return nil
        }
    }

    public func array(_ key: String) -> [JSONValue]? {
        if case .array(let a)? = values[key] { return a }
        return nil
    }

    public func object(_ key: String) -> [String: JSONValue]? {
        if case .object(let o)? = values[key] { return o }
        return nil
    }

    // MARK: - Serialization (for sending back to providers)

    public var jsonObject: [String: Any] {
        values.mapValues(\.anyValue)
    }

    public var jsonString: String {
        guard let data = try? JSONSerialization.data(withJSONObject: jsonObject),
              let s = String(data: data, encoding: .utf8)
        else { return "{}" }
        return s
    }
}
