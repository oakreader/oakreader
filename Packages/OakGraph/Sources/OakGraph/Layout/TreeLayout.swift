import Foundation
import SwiftUI

/// Hierarchical tree layout for mind maps using a modified Reingold-Tilford algorithm.
/// Root is placed at center; left subtrees go left, right subtrees go right.
public struct TreeLayout: LayoutEngine {
    /// Horizontal spacing between sibling nodes.
    public var horizontalSpacing: CGFloat = 60
    /// Vertical spacing between levels.
    public var verticalSpacing: CGFloat = 80

    public init(horizontalSpacing: CGFloat = 60, verticalSpacing: CGFloat = 80) {
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public func layout(_ document: inout GraphDocument) {
        guard !document.nodes.isEmpty else { return }

        document.autoSizeAllNodes()

        // Find root: node with no parentId, or first node
        let rootId = document.rootNodes.first?.id ?? document.nodes[0].id

        // Build children lookup
        var childrenMap: [UUID: [UUID]] = [:]
        for node in document.nodes {
            if let pid = node.parentId {
                childrenMap[pid, default: []].append(node.id)
            }
        }

        // Compute subtree sizes bottom-up
        var subtreeWidths: [UUID: CGFloat] = [:]
        computeSubtreeWidth(nodeId: rootId, childrenMap: childrenMap, document: document, result: &subtreeWidths)

        // Position the root at canvas center
        let center = CGPoint(x: document.canvasSize.width / 2, y: document.canvasSize.height / 2)

        // Split children into left and right halves
        let rootChildren = childrenMap[rootId] ?? []
        let mid = rootChildren.count / 2
        let leftChildren = Array(rootChildren.prefix(mid))
        let rightChildren = Array(rootChildren.suffix(from: mid))

        // Position root
        if let idx = document.nodeIndex(withId: rootId) {
            document.nodes[idx].position = center
        }

        // Layout right subtrees
        var rightY = center.y - totalHeight(children: rightChildren, subtreeWidths: subtreeWidths, document: document) / 2
        for childId in rightChildren {
            layoutSubtree(
                nodeId: childId,
                x: center.x + horizontalSpacing + nodeWidth(rootId, in: document) / 2,
                y: &rightY,
                direction: .right,
                childrenMap: childrenMap,
                subtreeWidths: subtreeWidths,
                document: &document
            )
        }

        // Layout left subtrees
        var leftY = center.y - totalHeight(children: leftChildren, subtreeWidths: subtreeWidths, document: document) / 2
        for childId in leftChildren {
            layoutSubtree(
                nodeId: childId,
                x: center.x - horizontalSpacing - nodeWidth(rootId, in: document) / 2,
                y: &leftY,
                direction: .left,
                childrenMap: childrenMap,
                subtreeWidths: subtreeWidths,
                document: &document
            )
        }
    }

    private enum Direction { case left, right }

    private func layoutSubtree(
        nodeId: UUID,
        x: CGFloat,
        y: inout CGFloat,
        direction: Direction,
        childrenMap: [UUID: [UUID]],
        subtreeWidths: [UUID: CGFloat],
        document: inout GraphDocument
    ) {
        let children = childrenMap[nodeId] ?? []
        let subtreeH = subtreeWidths[nodeId] ?? 40

        // Node position: centered vertically in its subtree
        let nodeX: CGFloat
        switch direction {
        case .right:
            nodeX = x + nodeWidth(nodeId, in: document) / 2
        case .left:
            nodeX = x - nodeWidth(nodeId, in: document) / 2
        }

        let nodeY = y + subtreeH / 2

        if let idx = document.nodeIndex(withId: nodeId) {
            document.nodes[idx].position = CGPoint(x: nodeX, y: nodeY)
        }

        // Layout children
        let childX: CGFloat
        switch direction {
        case .right:
            childX = nodeX + horizontalSpacing + nodeWidth(nodeId, in: document) / 2
        case .left:
            childX = nodeX - horizontalSpacing - nodeWidth(nodeId, in: document) / 2
        }

        var childY = y
        if !children.isEmpty {
            let totalChildHeight = children.reduce(CGFloat(0)) { sum, cid in
                sum + (subtreeWidths[cid] ?? 40)
            } + CGFloat(children.count - 1) * 8

            childY = nodeY - totalChildHeight / 2
        }

        for childId in children {
            layoutSubtree(
                nodeId: childId,
                x: childX,
                y: &childY,
                direction: direction,
                childrenMap: childrenMap,
                subtreeWidths: subtreeWidths,
                document: &document
            )
            childY += (subtreeWidths[childId] ?? 40) + 8
        }

        y += subtreeH + 8
    }

    private func computeSubtreeWidth(
        nodeId: UUID,
        childrenMap: [UUID: [UUID]],
        document: GraphDocument,
        result: inout [UUID: CGFloat]
    ) {
        let children = childrenMap[nodeId] ?? []
        if children.isEmpty {
            let nodeHeight = document.node(withId: nodeId)?.size.height ?? 40
            result[nodeId] = nodeHeight
            return
        }

        var totalHeight: CGFloat = 0
        for childId in children {
            computeSubtreeWidth(nodeId: childId, childrenMap: childrenMap, document: document, result: &result)
            totalHeight += result[childId] ?? 40
        }
        totalHeight += CGFloat(children.count - 1) * 8

        let nodeHeight = document.node(withId: nodeId)?.size.height ?? 40
        result[nodeId] = max(nodeHeight, totalHeight)
    }

    private func nodeWidth(_ nodeId: UUID, in document: GraphDocument) -> CGFloat {
        document.node(withId: nodeId)?.size.width ?? 120
    }

    private func totalHeight(children: [UUID], subtreeWidths: [UUID: CGFloat], document: GraphDocument) -> CGFloat {
        let heights = children.map { subtreeWidths[$0] ?? 40 }
        let spacing = max(0, CGFloat(children.count - 1)) * 8
        return heights.reduce(0, +) + spacing
    }
}
