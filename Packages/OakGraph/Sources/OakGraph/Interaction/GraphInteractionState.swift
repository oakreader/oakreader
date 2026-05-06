import Foundation
import SwiftUI

/// Observable state for graph canvas interaction (zoom, pan, selection, drag, editing).
@Observable
public class GraphInteractionState {
    /// Current zoom scale (0.25 to 4.0).
    public var scale: CGFloat = 1.0
    /// Canvas pan offset in view coordinates.
    public var offset: CGPoint = .zero

    /// Currently selected node.
    public var selectedNodeId: UUID?
    /// Currently selected edge.
    public var selectedEdgeId: UUID?

    /// Node being dragged.
    public var draggingNodeId: UUID?
    /// Accumulated drag translation.
    public var dragOffset: CGSize = .zero
    /// Node position when drag started.
    public var dragStartPosition: CGPoint = .zero

    /// Whether we are currently panning the canvas (dragging on empty space).
    public var isPanning: Bool = false
    /// Offset when pan started.
    public var panStartOffset: CGPoint = .zero

    /// Node being inline-edited.
    public var editingNodeId: UUID?
    /// Current text in the inline editor.
    public var editingText: String = ""

    public init() {}

    // MARK: - Selection

    public func selectNode(_ id: UUID) {
        selectedNodeId = id
        selectedEdgeId = nil
    }

    public func selectEdge(_ id: UUID) {
        selectedEdgeId = id
        selectedNodeId = nil
    }

    public func clearSelection() {
        selectedNodeId = nil
        selectedEdgeId = nil
    }

    public var hasSelection: Bool {
        selectedNodeId != nil || selectedEdgeId != nil
    }

    // MARK: - Zoom

    public func zoom(by factor: CGFloat, anchor: CGPoint = .zero) {
        let newScale = min(4.0, max(0.25, scale * factor))
        // Adjust offset to zoom toward anchor point
        let scaleDelta = newScale / scale
        offset = CGPoint(
            x: anchor.x - (anchor.x - offset.x) * scaleDelta,
            y: anchor.y - (anchor.y - offset.y) * scaleDelta
        )
        scale = newScale
    }

    public func resetZoom() {
        scale = 1.0
        offset = .zero
    }

    /// Adjust scale and offset so that `contentRect` fits within `viewSize` with padding.
    public func zoomToFit(contentRect: CGRect, viewSize: CGSize, padding: CGFloat = 40) {
        guard contentRect.width > 0, contentRect.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return }

        let availableWidth = viewSize.width - padding * 2
        let availableHeight = viewSize.height - padding * 2

        let scaleX = availableWidth / contentRect.width
        let scaleY = availableHeight / contentRect.height
        let fitScale = min(min(scaleX, scaleY), 2.0)

        scale = max(0.25, fitScale)
        offset = CGPoint(
            x: (viewSize.width - contentRect.width * scale) / 2 - contentRect.origin.x * scale,
            y: (viewSize.height - contentRect.height * scale) / 2 - contentRect.origin.y * scale
        )
    }

    // MARK: - Coordinate Transform

    /// Convert a point from view coordinates to canvas coordinates.
    public func viewToCanvas(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: (viewPoint.x - offset.x) / scale,
            y: (viewPoint.y - offset.y) / scale
        )
    }

    /// Convert a point from canvas coordinates to view coordinates.
    public func canvasToView(_ canvasPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: canvasPoint.x * scale + offset.x,
            y: canvasPoint.y * scale + offset.y
        )
    }

    // MARK: - Inline Editing

    public func beginEditing(nodeId: UUID, currentLabel: String) {
        editingNodeId = nodeId
        editingText = currentLabel
    }

    public func cancelEditing() {
        editingNodeId = nil
        editingText = ""
    }
}
