import SwiftUI

struct RootView: View {
    let appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar — sits in the title bar area (merged with traffic lights)
            TabBarView(appState: appState)

            // Content
            if let tab = appState.activeTab {
                // PDF view — no sidebar
                ContentView(viewModel: tab.viewModel)
                    .id(tab.id)
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
