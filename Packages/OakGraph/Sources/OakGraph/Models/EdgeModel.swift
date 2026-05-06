import Foundation

/// A directed edge connecting two nodes.
public struct EdgeModel: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    public var sourceId: UUID
    public var targetId: UUID
    /// Relationship label (e.g., "causes", "is part of"). Primarily used for concept maps.
    public var label: String
    public var style: EdgeStyle

    public init(
        id: UUID = UUID(),
        sourceId: UUID,
        targetId: UUID,
        label: String = "",
        style: EdgeStyle = .default
    ) {
        self.id = id
        self.sourceId = sourceId
        self.targetId = targetId
        self.label = label
        self.style = style
    }

    // Custom decoder: provides defaults for fields the LLM may omit.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.sourceId = try c.decode(UUID.self, forKey: .sourceId)
        self.targetId = try c.decode(UUID.self, forKey: .targetId)
        self.label = (try? c.decode(String.self, forKey: .label)) ?? ""
        self.style = (try? c.decode(EdgeStyle.self, forKey: .style)) ?? .default
    }
}
