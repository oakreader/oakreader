import SwiftUI

/// Chrome-inspired tab architecture:
/// All open tabs keep their view hierarchy alive in memory.
/// Switching tabs toggles visibility (opacity + hit-testing) rather than
/// destroying/recreating the entire view tree. This gives instant tab switches
/// because NSTextView, WKWebView, scroll positions, and editor state are preserved.
struct RootView: View {
    let appState: AppState
    @AppStorage("globalFontFamily") private var globalFontFamily: String = "system"
    @AppStorage("globalFontSize") private var globalFontSize: Double = 14.0

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar — sits in the title bar area (merged with traffic lights)
            TabBarView(appState: appState)

            // Content: all tabs coexist in a ZStack; only the active one is visible.
            ZStack {
                // Library view — shown when no tab is active
                LibraryRootView(appState: appState)
                    .opacity(appState.isLibraryActive ? 1 : 0)
                    .allowsHitTesting(appState.isLibraryActive)

                // Document tabs — each kept alive, visibility toggled
                ForEach(appState.openTabs) { tab in
                    ContentView(viewModel: tab.viewModel)
                        .environment(\.isTabActive, tab.id == appState.activeTabID)
                        .opacity(tab.id == appState.activeTabID ? 1 : 0)
                        .allowsHitTesting(tab.id == appState.activeTabID)
                }

            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: appState.activeTabID) { _, _ in
            // Reset cursor when switching tabs to prevent leaks from PDF/Web viewer cursor rects
            NSCursor.arrow.set()
        }
        .sheet(isPresented: Binding(
            get: { appState.showZoteroImport },
            set: { appState.showZoteroImport = $0 }
        )) {
            if let dataDir = appState.zoteroImportDataDir {
                ZoteroImportProgressView(
                    dataDirectory: dataDir,
                    store: appState.libraryStore,
                    coverService: appState.coverService,
                    referenceService: appState.referenceService,
                    onDismiss: {
                        appState.showZoteroImport = false
                        appState.zoteroImportDataDir = nil
                    }
                )
            }
        }
    }
}
