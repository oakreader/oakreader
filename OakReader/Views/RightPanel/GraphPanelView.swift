import SwiftUI
import OakGraph

/// Right panel view for the Graph Map feature.
/// Shows either a graph card list or the canvas editor.
struct GraphPanelView: View {
    @Bindable var graphVM: GraphViewModel

    var body: some View {
        VStack(spacing: 0) {
            if graphVM.selectedGraph != nil {
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
                Text("Graph Maps")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()

                Menu {
                    Button {
                        graphVM.generate(graphType: .conceptMap)
                    } label: {
                        Label("Concept Map", systemImage: "point.3.filled.connected.trianglepath.dotted")
                    }
                    Button {
                        graphVM.generate(graphType: .mindMap)
                    } label: {
                        Label("Mind Map", systemImage: "brain")
                    }
                } label: {
                    Image(systemName: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(graphVM.isGenerating)
                .help("Generate graph map from document")
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
            } else if graphVM.graphs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No graph maps yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Generate a concept map or mind map from your document using AI.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(graphVM.graphs) { graph in
                            GraphCardView(graph: graph)
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
                    }
                    .padding(8)
                }
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
                ) {
                    GraphToolbarButtons(graphVM: graphVM)
                }
            } else {
                Text("Failed to load graph.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Card View

private struct GraphCardView: View {
    let graph: GraphMapMeta

    private var typeBadge: String {
        graph.graphType == "mindMap" ? "Mind Map" : "Concept Map"
    }

    private var typeIcon: String {
        graph.graphType == "mindMap" ? "brain" : "point.3.filled.connected.trianglepath.dotted"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail cover
            thumbnailView
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .clipped()

            // Info row
            VStack(alignment: .leading, spacing: 4) {
                Text(graph.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    // Type badge
                    HStack(spacing: 3) {
                        Image(systemName: typeIcon)
                            .font(.system(size: 9))
                        Text(typeBadge)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.12), in: Capsule())
                    .foregroundStyle(.secondary)

                    Spacer()

                    Text(graph.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let data = graph.thumbnailData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFill()
        } else {
            // Placeholder
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Image(systemName: typeIcon)
                    .font(.system(size: 28))
                    .foregroundStyle(.quaternary)
            }
        }
    }
}
