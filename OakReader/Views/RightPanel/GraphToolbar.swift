import SwiftUI
import UniformTypeIdentifiers
import OakGraph

/// Toolbar for graph panel: layout, zoom, export, full-screen.
struct GraphToolbar: View {
    @Bindable var graphVM: GraphViewModel

    private var zoomPercentage: String {
        "\(Int(graphVM.interaction.scale * 100))%"
    }

    var body: some View {
        HStack(spacing: 6) {
            // Zoom controls
            Button(action: { graphVM.interaction.zoom(by: 0.8) }) {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Zoom out")

            Button(action: { graphVM.interaction.resetZoom() }) {
                Text(zoomPercentage)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(minWidth: 36)
            }
            .buttonStyle(.plain)
            .help("Reset zoom")

            Button(action: { graphVM.interaction.zoom(by: 1.25) }) {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .help("Zoom in")

            Spacer()

            // Re-layout
            Button(action: { graphVM.relayout() }) {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.plain)
            .help("Re-layout")

            // Full screen
            Button(action: { graphVM.isFullScreen = true }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Full screen")

            // Export menu
            Menu {
                Button("Export PNG") { exportPNG() }
                Button("Export SVG") { exportSVG() }
                Button("Export .oakgraph") { exportOakGraph() }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Export Actions

    private func exportPNG() {
        guard let data = graphVM.exportPNG() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(graphVM.currentDocument?.title ?? "graph").png"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }

    private func exportSVG() {
        guard let svg = graphVM.exportSVG() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        panel.nameFieldStringValue = "\(graphVM.currentDocument?.title ?? "graph").svg"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? svg.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func exportOakGraph() {
        guard let data = graphVM.exportJSON() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.oakgraph]
        let doc = graphVM.currentDocument
        let meta = GraphMapMeta(document: doc ?? GraphDocument())
        panel.nameFieldStringValue = meta.fileName
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }
}

extension UTType {
    static let oakgraph = UTType(exportedAs: "com.oakreader.oakgraph")
}
