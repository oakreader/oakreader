import SwiftUI
import UniformTypeIdentifiers
import OakGraph

/// Compact toolbar buttons for graph panel: relayout, full-screen, export.
/// Zoom controls are now built into GraphCanvasView.
struct GraphToolbarButtons: View {
    @Bindable var graphVM: GraphViewModel

    var body: some View {
        HStack(spacing: 6) {
            // Canvas actions pill
            HStack(spacing: 4) {
                Button(action: { graphVM.relayout() }) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Re-layout")

                Divider()
                    .frame(height: 14)

                Button(action: { graphVM.enterFullScreen() }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Full screen")
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)

            // More / export pill
            Menu {
                Button("Export PNG") { exportPNG() }
                Button("Export SVG") { exportSVG() }
                Button("Export .oakgraph") { exportOakGraph() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            .help("More")
        }
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
