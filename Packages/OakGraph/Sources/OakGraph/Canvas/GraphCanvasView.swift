import SwiftUI

/// Main graph canvas view providing rendering, zoom, pan, and interaction.
public struct GraphCanvasView: View {
    @Bindable var interaction: GraphInteractionState
    let document: GraphDocument

    // Callbacks
    var onNodeMoved: ((UUID, CGPoint) -> Void)?
    var onNodeSelected: ((UUID?) -> Void)?
    var onEdgeSelected: ((UUID?) -> Void)?
    var onNodeDoubleTapped: ((UUID) -> Void)?
    var onDeleteRequested: (() -> Void)?
    var onEditCommitted: ((UUID, String) -> Void)?

    public init(
        interaction: GraphInteractionState,
        document: GraphDocument,
        onNodeMoved: ((UUID, CGPoint) -> Void)? = nil,
        onNodeSelected: ((UUID?) -> Void)? = nil,
        onEdgeSelected: ((UUID?) -> Void)? = nil,
        onNodeDoubleTapped: ((UUID) -> Void)? = nil,
        onDeleteRequested: (() -> Void)? = nil,
        onEditCommitted: ((UUID, String) -> Void)? = nil
    ) {
        self.interaction = interaction
        self.document = document
        self.onNodeMoved = onNodeMoved
        self.onNodeSelected = onNodeSelected
        self.onEdgeSelected = onEdgeSelected
        self.onNodeDoubleTapped = onNodeDoubleTapped
        self.onDeleteRequested = onDeleteRequested
        self.onEditCommitted = onEditCommitted
    }

    public var body: some View {
        ZStack {
            canvas
            inlineEditorOverlay
        }
        .clipped()
        .onKeyPress(.delete) {
            onDeleteRequested?()
            return .handled
        }
        .focusable()
    }

    // MARK: - Canvas

    private var canvas: some View {
        Canvas { context, size in
            // Apply zoom + pan transform
            context.translateBy(x: interaction.offset.x, y: interaction.offset.y)
            context.scaleBy(x: interaction.scale, y: interaction.scale)

            let canvasSize = document.canvasSize

            // Draw edges first (behind nodes)
            for edge in document.edges {
                guard let source = document.node(withId: edge.sourceId),
                      let target = document.node(withId: edge.targetId) else { continue }

                EdgeRenderer.draw(
                    edge: edge,
                    source: effectiveNode(source),
                    target: effectiveNode(target),
                    isSelected: edge.id == interaction.selectedEdgeId,
                    in: &context,
                    canvasSize: canvasSize
                )
            }

            // Draw nodes on top
            for node in document.nodes {
                let effectiveNode = effectiveNode(node)
                NodeRenderer.draw(
                    node: effectiveNode,
                    isSelected: node.id == interaction.selectedNodeId,
                    in: &context,
                    canvasSize: canvasSize
                )
            }
        }
        .gesture(dragGesture)
        .gesture(magnificationGesture)
        .gesture(tapGesture)
        .simultaneousGesture(doubleTapGesture)
    }

    /// Returns the node with drag offset applied if it's the node being dragged.
    private func effectiveNode(_ node: NodeModel) -> NodeModel {
        guard node.id == interaction.draggingNodeId else { return node }
        var moved = node
        moved.position = CGPoint(
            x: interaction.dragStartPosition.x + interaction.dragOffset.width / interaction.scale,
            y: interaction.dragStartPosition.y + interaction.dragOffset.height / interaction.scale
        )
        return moved
    }

    // MARK: - Inline Editor Overlay

    @ViewBuilder
    private var inlineEditorOverlay: some View {
        if let editingId = interaction.editingNodeId,
           let node = document.node(withId: editingId) {
            let viewPos = interaction.canvasToView(node.position)
            TextField("Label", text: $interaction.editingText, onCommit: {
                onEditCommitted?(editingId, interaction.editingText)
                interaction.cancelEditing()
            })
            .textFieldStyle(.plain)
            .font(.system(size: node.style.textStyle.fontSize * interaction.scale))
            .multilineTextAlignment(.center)
            .frame(width: node.size.width * interaction.scale + 20)
            .padding(4)
            .background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 4))
            .position(viewPos)
        }
    }

    // MARK: - Gestures

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard interaction.editingNodeId == nil else {
                    interaction.cancelEditing()
                    return
                }
                let canvasPoint = interaction.viewToCanvas(value.location)

                if let nodeId = HitTesting.nodeAt(point: canvasPoint, in: document) {
                    interaction.selectNode(nodeId)
                    onNodeSelected?(nodeId)
                } else if let edgeId = HitTesting.edgeAt(point: canvasPoint, in: document) {
                    interaction.selectEdge(edgeId)
                    onEdgeSelected?(edgeId)
                } else {
                    interaction.clearSelection()
                    onNodeSelected?(nil)
                }
            }
    }

    private var doubleTapGesture: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                let canvasPoint = interaction.viewToCanvas(value.location)
                if let nodeId = HitTesting.nodeAt(point: canvasPoint, in: document) {
                    if let node = document.node(withId: nodeId) {
                        interaction.beginEditing(nodeId: nodeId, currentLabel: node.label)
                    }
                    onNodeDoubleTapped?(nodeId)
                }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if interaction.draggingNodeId == nil && !interaction.isPanning {
                    // Determine if dragging a node or panning
                    let startCanvas = interaction.viewToCanvas(value.startLocation)
                    if let nodeId = HitTesting.nodeAt(point: startCanvas, in: document),
                       let node = document.node(withId: nodeId) {
                        interaction.draggingNodeId = nodeId
                        interaction.dragStartPosition = node.position
                        interaction.selectNode(nodeId)
                        onNodeSelected?(nodeId)
                    } else {
                        interaction.isPanning = true
                        interaction.panStartOffset = interaction.offset
                    }
                }

                if interaction.draggingNodeId != nil {
                    interaction.dragOffset = value.translation
                } else if interaction.isPanning {
                    interaction.offset = CGPoint(
                        x: interaction.panStartOffset.x + value.translation.width,
                        y: interaction.panStartOffset.y + value.translation.height
                    )
                }
            }
            .onEnded { value in
                if let nodeId = interaction.draggingNodeId {
                    let newPosition = CGPoint(
                        x: interaction.dragStartPosition.x + value.translation.width / interaction.scale,
                        y: interaction.dragStartPosition.y + value.translation.height / interaction.scale
                    )
                    onNodeMoved?(nodeId, newPosition)
                }
                interaction.draggingNodeId = nil
                interaction.dragOffset = .zero
                interaction.isPanning = false
            }
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let factor = value.magnification
                let newScale = min(4.0, max(0.25, interaction.scale * factor))
                interaction.scale = newScale
            }
    }
}
