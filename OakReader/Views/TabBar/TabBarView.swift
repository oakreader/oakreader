import SwiftUI

struct TabBarView: View {
    let appState: AppState

    // Leave space for macOS traffic light buttons (close/minimize/zoom)
    private let trafficLightPadding: CGFloat = 80
    private let fullScreenPadding: CGFloat = 8

    @State private var isFullScreen = false
    @State private var isPinnedHovering = false

    private var store: LibraryStore { appState.libraryStore }

    var body: some View {
        HStack(spacing: 0) {
            // Pinned collection tab (always visible)
            Button {
                appState.switchToLibrary()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: pinnedTabIcon)
                        .font(.system(size: ZoteroStyle.Font.icon))
                    Text(pinnedTabTitle)
                        .font(.system(size: ZoteroStyle.Font.body, weight: .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 16)
                .frame(height: ZoteroStyle.Size.tabHeight)
                .frame(maxWidth: ZoteroStyle.Size.tabMax, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(appState.isLibraryActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
            .background(pinnedTabShape)
            .onHover { isPinnedHovering = $0 }
            .padding(.trailing, 2)

            if !appState.openTabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(appState.openTabs) { tab in
                            DocumentTabView(
                                tab: tab,
                                isActive: tab.id == appState.activeTabID,
                                onSelect: { appState.switchToTab(tab.id) },
                                onClose: { appState.closeTab(tab.id) }
                            )
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.leading, isFullScreen ? fullScreenPadding : trafficLightPadding)
        .padding(.top, 4)
        .frame(height: ZoteroStyle.Size.tabBarHeight)
        .background(ZoteroStyle.Colors.tabBarBackground)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }

    // MARK: - Pinned Tab Content

    private var pinnedTabTitle: String {
        if let col = store.selectedCollection {
            return col.name
        }
        return store.currentFilter.rawValue
    }

    private var pinnedTabIcon: String {
        if let col = store.selectedCollection {
            return col.icon
        }
        return store.currentFilter.icon
    }

    @ViewBuilder
    private var pinnedTabShape: some View {
        if appState.isLibraryActive {
            RoundedRectangle(cornerRadius: ZoteroStyle.Radius.standard)
                .fill(Color.primary.opacity(0.10))
                .padding(.vertical, 6)
        } else if isPinnedHovering {
            RoundedRectangle(cornerRadius: ZoteroStyle.Radius.standard)
                .fill(Color.primary.opacity(0.07))
                .padding(.vertical, 6)
        }
        // Inactive + not hovering: transparent
    }
}
