import SwiftUI
import OakGraph

struct RootView: View {
    let appState: AppState
    @AppStorage("globalFontFamily") private var globalFontFamily: String = "system"
    @AppStorage("globalFontSize") private var globalFontSize: Double = 14.0

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar — sits in the title bar area (merged with traffic lights)
            TabBarView(appState: appState)

            // Content
            if let tab = appState.activeTab {
                if case .graph(let doc, _) = tab.content {
                    StandaloneGraphView(document: doc)
                        .id(tab.id)
                } else {
                    ContentView(viewModel: tab.viewModel)
                        .id(tab.id)
                }
            } else {
                // Library view — 3-pane with sidebar
                LibraryRootView(appState: appState)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: Binding(
            get: { appState.showSettings },
            set: { appState.showSettings = $0 }
        )) {
            SettingsView(store: appState.libraryStore)
        }
    }
}

/// Full-screen read-only graph viewer for standalone .oakgraph files.
private struct StandaloneGraphView: View {
    let document: GraphDocument
    @State private var interaction = GraphInteractionState()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Text(document.title.isEmpty ? "Graph" : document.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)

                Spacer()

                Text(document.graphType == .mindMap ? "Mind Map" : "Concept Map")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            GraphCanvasView(
                interaction: interaction,
                document: document,
                onNodeMoved: { _, _ in },
                onNodeSelected: { _ in },
                onEdgeSelected: { _ in },
                onNodeDoubleTapped: { _ in },
                onDeleteRequested: {},
                onEditCommitted: { _, _ in }
            )
        }
        .background(OakStyle.Colors.contentBackground)
    }
}
