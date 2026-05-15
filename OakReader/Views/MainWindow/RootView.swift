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
        .overlay(alignment: .top) {
            if let message = appState.importNotification {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .padding(.top, 48)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                appState.importNotification = nil
                            }
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.importNotification)
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
