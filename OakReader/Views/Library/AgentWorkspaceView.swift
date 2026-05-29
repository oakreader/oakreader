import SwiftUI

/// Full-page AI agent workspace shown in the library window (Dia-style).
/// The collection sidebar (rendered by `LibraryRootView`) — or an item bound via
/// "Open in Agent Workspace" — selects the agent's "current workspace". This pane
/// hosts the chat canvas scoped to that workspace's on-disk folder.
struct AgentWorkspaceView: View {
    let appState: AppState

    private var store: LibraryStore { appState.libraryStore }

    /// Human-readable name of the current workspace, or nil for the whole library.
    /// Mirrors the binding `AppState.refreshAgentWorkspace` resolves: a bound item,
    /// else a real (non-smart) user collection, else the general/whole-library scope.
    private var workspaceName: String? {
        if let key = appState.agentBoundItemStorageKey,
           let item = store.items.first(where: { $0.storageKey == key }) {
            return item.title
        }
        guard let collection = store.selectedCollection,
              collection.id != SystemCollectionID.allItems,
              !collection.isSmart else { return nil }
        return collection.name
    }

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)

            let paneShape = UnevenRoundedRectangle(
                topLeadingRadius: OakStyle.Radius.standard,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: OakStyle.Radius.standard
            )

            AIChatView(
                chatVM: appState.libraryChatVM,
                presentation: .canvas,
                workspaceName: workspaceName,
                onClearWorkspace: workspaceName != nil ? clearWorkspace : nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OakStyle.Colors.diaSurface, in: paneShape)
            .clipShape(paneShape)
        }
        .onAppear { appState.refreshAgentWorkspace() }
        .onChange(of: store.selectedCollectionId) { _, _ in
            // Selecting a collection in the sidebar overrides any bound item.
            appState.agentBoundItemStorageKey = nil
            appState.refreshAgentWorkspace()
        }
        .onChange(of: appState.agentBoundItemStorageKey) { _, _ in
            appState.refreshAgentWorkspace()
        }
    }

    private func clearWorkspace() {
        appState.agentBoundItemStorageKey = nil
        store.selectCollection(SystemCollectionID.allItems)
        appState.refreshAgentWorkspace()
    }
}
