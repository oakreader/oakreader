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
            // Sidebar toggle
            Button {
                if let viewModel = appState.activeTab?.viewModel {
                    viewModel.state.isSidebarVisible.toggle()
                } else {
                    appState.isLibrarySidebarVisible.toggle()
                }
            } label: {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(sidebarToggleActive ? Color.accentColor : Color(nsColor: .labelColor))
            .help("Toggle Sidebar")
            .padding(.trailing, 4)

            // Pinned collection tab (always visible)
            Button {
                appState.switchToLibrary()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: pinnedTabIcon)
                        .font(.system(size: OakStyle.Font.icon))
                    Text(pinnedTabTitle)
                        .font(.system(size: OakStyle.Font.body, weight: .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 16)
                .frame(height: OakStyle.Size.tabHeight)
                .frame(maxWidth: OakStyle.Size.tabMax, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(appState.isLibraryActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
            .background(pinnedTabShape)
            .onHover { isPinnedHovering = $0 }
            .padding(.trailing, 8)

            if !appState.openTabs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(appState.openTabs.enumerated()), id: \.element.id) { index, tab in
                            DocumentTabView(
                                tab: tab,
                                isActive: tab.id == appState.activeTabID,
                                isFirst: index == 0,
                                onSelect: { appState.switchToTab(tab.id) },
                                onClose: { appState.closeTab(tab.id) }
                            )
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // Settings button — right end, aligned with SideNav column
            Button {
                appState.showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: OakStyle.Font.icon))
                    .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(appState.showSettings ? Color.accentColor : Color(nsColor: .labelColor))
            .help("Settings")
            .frame(width: OakStyle.Size.sidenavWidth)
        }
        .padding(.leading, isFullScreen ? fullScreenPadding : trafficLightPadding)
        .frame(height: OakStyle.Size.tabBarHeight)
        .background(OakStyle.Colors.tabBarBackground)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }

    // MARK: - Sidebar Toggle

    private var sidebarToggleActive: Bool {
        if let viewModel = appState.activeTab?.viewModel {
            return viewModel.state.isSidebarVisible
        }
        return appState.isLibrarySidebarVisible
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
            RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                .fill(OakStyle.Colors.activeTabBackground)
                .padding(.vertical, 6)
        } else if isPinnedHovering {
            RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                .fill(Color.primary.opacity(0.08))
                .padding(.vertical, 6)
        }
        // Inactive + not hovering: transparent (gray tab bar shows through)
    }
}
