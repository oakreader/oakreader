import SwiftUI

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
