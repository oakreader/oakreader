import Foundation
import SwiftUI

/// Top-level graph container. This is what the LLM produces and what gets serialized to disk.
public struct GraphDocument: Codable, Sendable {
    public let id: UUID
    public var title: String
    public var graphType: GraphType
    public var nodes: [NodeModel]
    public var edges: [EdgeModel]
    public var canvasSize: CGSize

    public init(
        id: UUID = UUID(),
        title: String = "",
        graphType: GraphType = .conceptMap,
        nodes: [NodeModel] = [],
        edges: [EdgeModel] = [],
        canvasSize: CGSize = CGSize(width: 2000, height: 2000)
    ) {
        self.id = id
        self.title = title
        self.graphType = graphType
        self.nodes = nodes
        self.edges = edges
        self.canvasSize = canvasSize
    }

    /// Look up a node by ID.
    public func node(withId id: UUID) -> NodeModel? {
        nodes.first { $0.id == id }
    }

    /// Look up a node index by ID.
    public func nodeIndex(withId id: UUID) -> Int? {
        nodes.firstIndex { $0.id == id }
    }

    /// All edges connected to a given node.
    public func edges(for nodeId: UUID) -> [EdgeModel] {
        edges.filter { $0.sourceId == nodeId || $0.targetId == nodeId }
    }

    /// Children of a node (for tree structures).
    public func children(of nodeId: UUID) -> [NodeModel] {
        nodes.filter { $0.parentId == nodeId }
    }

    /// Root nodes (nodes with no parent).
    public var rootNodes: [NodeModel] {
        nodes.filter { $0.parentId == nil }
    }

    /// Auto-size all nodes based on their labels.
    public mutating func autoSizeAllNodes() {
        for i in nodes.indices {
            nodes[i].autoSize()
        }
    }

    /// Remove a node and all connected edges.
    public mutating func removeNode(_ nodeId: UUID) {
        nodes.removeAll { $0.id == nodeId }
        edges.removeAll { $0.sourceId == nodeId || $0.targetId == nodeId }
        // Re-parent children to the removed node's parent
        let parentId = nodes.first { $0.id == nodeId }?.parentId
        for i in nodes.indices where nodes[i].parentId == nodeId {
            nodes[i].parentId = parentId
        }
    }

    /// Remove an edge by ID.
    public mutating func removeEdge(_ edgeId: UUID) {
        edges.removeAll { $0.id == edgeId }
    }

    /// Filter out edges that reference non-existent nodes.
    public mutating func sanitizeEdges() {
        let nodeIds = Set(nodes.map(\.id))
        edges.removeAll { !nodeIds.contains($0.sourceId) || !nodeIds.contains($0.targetId) }
    }
}
