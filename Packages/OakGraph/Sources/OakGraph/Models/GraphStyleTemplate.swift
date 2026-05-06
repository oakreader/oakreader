import Foundation
import SwiftUI

/// Encapsulates all visual styling for a graph document.
/// AI produces only semantic structure; the template stamps visuals post-generation.
public struct GraphStyleTemplate: Sendable {
    /// Node color palette to cycle through.
    public var nodePalette: [NodeStyle]
    /// Text style applied to root / first nodes.
    public var rootNodeTextStyle: TextStyle
    /// Edge style used for concept maps (arrows).
    public var conceptMapEdgeStyle: EdgeStyle
    /// Edge style used for mind maps (no arrows).
    public var mindMapEdgeStyle: EdgeStyle

    public init(
        nodePalette: [NodeStyle],
        rootNodeTextStyle: TextStyle,
        conceptMapEdgeStyle: EdgeStyle,
        mindMapEdgeStyle: EdgeStyle
    ) {
        self.nodePalette = nodePalette
        self.rootNodeTextStyle = rootNodeTextStyle
        self.conceptMapEdgeStyle = conceptMapEdgeStyle
        self.mindMapEdgeStyle = mindMapEdgeStyle
    }

    /// Apply this template's visual styles to a `GraphDocument`.
    ///
    /// - Concept maps: cycles palette colors across nodes by flat index.
    /// - Mind maps: each top-level branch of the root gets one palette color;
    ///   all descendants of that branch share the same color.
    /// - Root nodes get the `rootNodeTextStyle`.
    /// - Edge styles are set based on graph type.
    ///
    /// Must run **before** `autoSizeAllNodes()` because `autoSize()` reads
    /// `style.textStyle.isBold` and `style.textStyle.fontSize`.
    public func apply(to document: inout GraphDocument) {
        guard !nodePalette.isEmpty else { return }

        let isDefault = { (s: NodeStyle) in s == .default }

        switch document.graphType {
        case .mindMap:
            applyMindMapNodeStyles(to: &document, isDefault: isDefault)
        case .conceptMap:
            applyConceptMapNodeStyles(to: &document, isDefault: isDefault)
        }

        // Bold the root / first node
        if let rootIdx = document.nodes.firstIndex(where: { $0.parentId == nil }) {
            document.nodes[rootIdx].style.textStyle = rootNodeTextStyle
        }

        // Apply edge styles based on graph type
        let edgeStyle = document.graphType == .mindMap ? mindMapEdgeStyle : conceptMapEdgeStyle
        for i in document.edges.indices {
            document.edges[i].style = edgeStyle
        }
    }

    // MARK: - Private

    /// Concept map: cycle palette by flat index.
    private func applyConceptMapNodeStyles(
        to document: inout GraphDocument,
        isDefault: (NodeStyle) -> Bool
    ) {
        for i in document.nodes.indices {
            guard isDefault(document.nodes[i].style) else { continue }
            document.nodes[i].style = nodePalette[i % nodePalette.count]
        }
    }

    /// Mind map: each top-level branch shares one palette color.
    private func applyMindMapNodeStyles(
        to document: inout GraphDocument,
        isDefault: (NodeStyle) -> Bool
    ) {
        // Find the root node (first node with no parent).
        guard let root = document.nodes.first(where: { $0.parentId == nil }) else {
            // Fallback to flat cycling if no root found.
            applyConceptMapNodeStyles(to: &document, isDefault: isDefault)
            return
        }

        // Style the root itself with the first palette color.
        if let rootIdx = document.nodeIndex(withId: root.id), isDefault(document.nodes[rootIdx].style) {
            document.nodes[rootIdx].style = nodePalette[0]
        }

        // Build a map from node ID → branch index for coloring.
        let topLevelChildren = document.children(of: root.id)
        var branchColor: [UUID: Int] = [:]

        for (branchIdx, child) in topLevelChildren.enumerated() {
            let colorIdx = branchIdx % nodePalette.count
            branchColor[child.id] = colorIdx
            assignBranchColor(child.id, colorIdx: colorIdx, document: &document, branchColor: &branchColor)
        }

        // Apply the computed branch colors.
        for i in document.nodes.indices {
            guard isDefault(document.nodes[i].style) else { continue }
            if let colorIdx = branchColor[document.nodes[i].id] {
                document.nodes[i].style = nodePalette[colorIdx]
            } else {
                // Nodes not reachable from root — fallback to flat index.
                document.nodes[i].style = nodePalette[i % nodePalette.count]
            }
        }
    }

    /// Recursively assign a branch color index to all descendants.
    private func assignBranchColor(
        _ nodeId: UUID,
        colorIdx: Int,
        document: inout GraphDocument,
        branchColor: inout [UUID: Int]
    ) {
        for child in document.children(of: nodeId) {
            branchColor[child.id] = colorIdx
            assignBranchColor(child.id, colorIdx: colorIdx, document: &document, branchColor: &branchColor)
        }
    }
}

// MARK: - Presets

extension GraphStyleTemplate {
    /// Default 8-color palette matching the original styling.
    public static let `default` = GraphStyleTemplate(
        nodePalette: [
            NodeStyle(fillColorHex: "#E3F2FD", borderColorHex: "#1976D2"),
            NodeStyle(fillColorHex: "#F3E5F5", borderColorHex: "#7B1FA2"),
            NodeStyle(fillColorHex: "#E8F5E9", borderColorHex: "#388E3C"),
            NodeStyle(fillColorHex: "#FFF3E0", borderColorHex: "#E65100"),
            NodeStyle(fillColorHex: "#FCE4EC", borderColorHex: "#C62828"),
            NodeStyle(fillColorHex: "#E0F7FA", borderColorHex: "#00838F"),
            NodeStyle(fillColorHex: "#FFF9C4", borderColorHex: "#F9A825"),
            NodeStyle(fillColorHex: "#F1F8E9", borderColorHex: "#558B2F"),
        ],
        rootNodeTextStyle: TextStyle(fontSize: 16, isBold: true),
        conceptMapEdgeStyle: .default,
        mindMapEdgeStyle: .mindMap
    )

    /// Monochrome theme with grey tones and clean borders.
    public static let monochrome = GraphStyleTemplate(
        nodePalette: [
            NodeStyle(fillColorHex: "#F5F5F5", borderColorHex: "#616161"),
            NodeStyle(fillColorHex: "#EEEEEE", borderColorHex: "#757575"),
            NodeStyle(fillColorHex: "#E0E0E0", borderColorHex: "#424242"),
            NodeStyle(fillColorHex: "#FAFAFA", borderColorHex: "#9E9E9E"),
        ],
        rootNodeTextStyle: TextStyle(fontSize: 16, isBold: true),
        conceptMapEdgeStyle: EdgeStyle(colorHex: "#424242"),
        mindMapEdgeStyle: EdgeStyle(
            lineType: .bezier,
            sourceArrow: .none,
            targetArrow: .none,
            colorHex: "#757575",
            thickness: 2
        )
    )
}
