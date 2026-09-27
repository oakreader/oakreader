import Foundation

/// A tool call's arguments, as the model sent them.
///
/// Holds parsed JSON rather than a string so a tool can read a nested array
/// directly while a scalar stays ergonomic: `input["query"]`.
struct ToolInput: Codable, Sendable, Hashable, ExpressibleByDictionaryLiteral {
    var values: [String: JSONValue]

    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.values = Dictionary(uniqueKeysWithValues: elements)
    }

    /// Build from a Foundation JSON object.
    init(jsonObject: [String: Any]) {
        self.values = jsonObject.mapValues(JSONValue.init(any:))
    }

    // Transparent Codable: encodes and decodes as the bare JSON object.
    init(from decoder: Decoder) throws {
        self.values = try [String: JSONValue](from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try values.encode(to: encoder)
    }

    // MARK: - Access

    /// Scalar access; an object or array renders as its JSON text.
    subscript(_ key: String) -> String? {
        values[key]?.scalarString
    }

    /// Every argument as a string, which is what the portable tools read.
    ///
    /// A model sometimes sends a number where the schema says string
    /// ("limit": 20), so scalars are flattened rather than dropped.
    var stringValues: [String: String] {
        values.compactMapValues(\.scalarString)
    }

    /// For sending back to a provider.
    var jsonObject: [String: Any] {
        values.mapValues(\.anyValue)
    }
}
