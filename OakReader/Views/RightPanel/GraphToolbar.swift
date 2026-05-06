import SwiftUI
import UniformTypeIdentifiers
import OakGraph

/// Toolbar for graph panel: layout, export, type switching.
struct GraphToolbar: View {
    @Bindable var graphVM: GraphViewModel

    var body: some View {
        HStack(spacing: 6) {
            // Graph type picker
            Picker("Type", selection: graphTypeBinding) {
                Text("Concept Map").tag(GraphType.conceptMap)
                Text("Mind Map").tag(GraphType.mindMap)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

            Spacer()

            // Re-layout
            Button(action: { graphVM.relayout() }) {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .help("Re-layout")

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

    private var graphTypeBinding: Binding<GraphType> {
        Binding(
            get: { graphVM.currentDocument?.graphType ?? .conceptMap },
            set: { graphVM.switchGraphType($0) }
        )
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
