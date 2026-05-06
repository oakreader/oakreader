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
}
