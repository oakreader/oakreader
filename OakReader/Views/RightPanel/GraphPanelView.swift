import SwiftUI
import OakGraph

/// Right panel view for the Graph Map feature.
/// Shows either a graph list or the canvas with toolbar.
struct GraphPanelView: View {
    @Bindable var graphVM: GraphViewModel
    let graphType: GraphType

    private var filteredGraphs: [GraphMapMeta] {
        graphVM.graphs(ofType: graphType)
    }

    private var headerTitle: String {
        graphType == .conceptMap ? "Concept Maps" : "Mind Maps"
    }

    var body: some View {
        VStack(spacing: 0) {
            if graphVM.selectedGraphId != nil {
                graphEditorView
            } else {
                graphListView
            }
        }
    }

    // MARK: - List View

    private var graphListView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text(headerTitle)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()

                Button {
                    graphVM.generate(graphType: graphType)
                } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.plain)
                .help("Generate \(graphType == .conceptMap ? "concept map" : "mind map") from document")
                .disabled(graphVM.isGenerating)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if graphVM.isGenerating {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Generating graph...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel") {
                        graphVM.stopGeneration()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredGraphs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: graphType == .conceptMap
                          ? "point.3.connected.trianglepath.dotted"
                          : "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No \(graphType == .conceptMap ? "concept maps" : "mind maps") yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Generate a \(graphType == .conceptMap ? "concept map" : "mind map") from your document using AI.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredGraphs) { graph in
                    GraphListRow(graph: graph)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            graphVM.selectGraph(graph)
                        }
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                graphVM.deleteGraph(graph)
                            }
                        }
                }
                .listStyle(.plain)
            }

            if let error = graphVM.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(8)
                .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Editor View

    private var graphEditorView: some View {
        VStack(spacing: 0) {
            // Back button + title
            HStack(spacing: 8) {
                Button(action: { graphVM.deselectGraph() }) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)

                Text(graphVM.selectedGraph?.displayTitle ?? "Graph")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Toolbar
            GraphToolbar(graphVM: graphVM)

            Divider()

            // Canvas
            if let doc = graphVM.currentDocument {
                GraphCanvasView(
                    interaction: graphVM.interaction,
                    document: doc,
                    onNodeMoved: { nodeId, position in
                        graphVM.moveNode(nodeId, to: position)
                    },
                    onNodeSelected: { _ in },
                    onEdgeSelected: { _ in },
                    onNodeDoubleTapped: { _ in },
                    onDeleteRequested: {
                        graphVM.deleteSelected()
                    },
                    onEditCommitted: { nodeId, newLabel in
                        graphVM.updateNodeLabel(nodeId, label: newLabel)
                    }
                )
            } else {
                Text("Failed to load graph.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - List Row

private struct GraphListRow: View {
    let graph: GraphMapMeta

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: graph.graphType == "mindMap" ? "point.3.filled.connected.trianglepath.dotted" : "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(graph.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(graph.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}
