import SwiftUI

struct TabBarView: View {
    let appState: AppState

    // Leave space for macOS traffic light buttons (close/minimize/zoom)
    private let trafficLightPadding: CGFloat = 80
    private let fullScreenPadding: CGFloat = 8

    @State private var isFullScreen = false
    @State private var isPinnedHovering = false
    @State private var pluginRefresh = false

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
            .accessibilityLabel("Toggle Sidebar")
            .padding(.trailing, 4)

            // Pinned collection tab (always visible)
            Button {
                appState.switchToLibrary()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: pinnedTabIcon)
                        .font(.system(size: OakStyle.Font.icon))
                    Text(pinnedTabTitle)
                        .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .regular))
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
            .help("Library: \(pinnedTabTitle)")
            .padding(.trailing, 8)

            if !appState.openTabs.isEmpty || appState.quizReviewSession != nil {
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

                        if let session = appState.quizReviewSession {
                            QuizTabView(
                                isActive: appState.activeTabID == session.tabID,
                                isFirst: appState.openTabs.isEmpty,
                                onSelect: { appState.activeTabID = session.tabID },
                                onClose: { appState.closeQuizReview() }
                            )
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // Panel mode tabs — context-dependent
            if let viewModel = appState.activeTab?.viewModel,
               viewModel.storageKey != nil,
               !viewModel.state.isZenMode {
                // Document tab: show document panel modes
                HStack(spacing: 4) {
                    ForEach(panelVisibleModes) { mode in
                        panelTabButton(mode: mode, viewModel: viewModel)
                    }
                }
                .padding(.trailing, 4)
            } else if appState.isLibraryActive {
                // Library tab: show library detail tabs
                HStack(spacing: 4) {
                    ForEach(LibraryDetailTab.allCases) { tab in
                        libraryTabButton(tab: tab)
                    }
                }
                .padding(.trailing, 4)
            }

        }
        .padding(.trailing, OakStyle.Spacing.xs)
        .padding(.leading, isFullScreen ? fullScreenPadding : trafficLightPadding)
        .frame(height: OakStyle.Size.tabBarHeight)
        .background(.thinMaterial)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let modes = panelVisibleModes
            if let vm = appState.activeTab?.viewModel,
               let current = vm.state.rightPanelMode,
               !modes.contains(current) {
                vm.state.rightPanelMode = nil
            }
            pluginRefresh.toggle()
        }
    }

    // MARK: - Sidebar Toggle

    private var sidebarToggleActive: Bool {
        if let viewModel = appState.activeTab?.viewModel {
            return viewModel.state.isSidebarVisible
        }
        return appState.isLibrarySidebarVisible
    }

    // MARK: - Panel Mode Tabs

    private var panelVisibleModes: [RightPanelMode] {
        _ = pluginRefresh
        let disabledModes = AppExtension.allCases
            .filter { !Preferences.shared.isExtensionEnabled($0) }
            .flatMap(\.rightPanelModes)
        return RightPanelMode.allCases.filter { !disabledModes.contains($0) }
    }

    private func panelTabButton(mode: RightPanelMode, viewModel: DocumentViewModel) -> some View {
        PanelTabButtonView(mode: mode, viewModel: viewModel)
    }

    // MARK: - Library Detail Tabs

    private func libraryTabButton(tab: LibraryDetailTab) -> some View {
        LibraryTabButtonView(tab: tab, appState: appState)
    }

    // MARK: - Pinned Tab Content

    private var pinnedTabTitle: String {
        store.selectedCollection?.name ?? "All Items"
    }

    private var pinnedTabIcon: String {
        store.selectedCollection?.icon ?? "books.vertical"
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

// MARK: - Quiz Tab View

struct QuizTabView: View {
    let isActive: Bool
    let isFirst: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false
    @State private var isCloseHovering = false

    private let cr: CGFloat = 10

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: OakStyle.Font.icon))
            Text("Quiz")
                .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .regular))
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isCloseHovering ? Color(nsColor: .labelColor) : .secondary)
                    .frame(
                        width: OakStyle.Size.closeButton,
                        height: OakStyle.Size.closeButton
                    )
                    .background(
                        RoundedRectangle(cornerRadius: OakStyle.Radius.small)
                            .fill(isCloseHovering ? Color.primary.opacity(0.1) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isCloseHovering = $0 }
            .opacity(isActive || isHovering ? 1 : 0)
            .accessibilityLabel("Close Quiz")
        }
        .padding(.leading, 10 + cr)
        .padding(.trailing, 10 + cr)
        .frame(height: OakStyle.Size.tabHeight)
        .frame(minWidth: OakStyle.Size.tabMin + cr * 2,
               maxWidth: OakStyle.Size.tabMax + cr * 2)
        .foregroundStyle(isActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
        .background(tabShape)
        .padding(.leading, isFirst ? 0 : -cr + 3)
        .padding(.trailing, -cr + 3)
        .zIndex(isActive ? 2 : isHovering ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tab: Quiz")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    @ViewBuilder
    private var tabShape: some View {
        if isActive {
            BrowserTabShape(concaveRadius: cr)
                .fill(OakStyle.Colors.activeTabBackground)
                .padding(.top, 6)
        } else if isHovering {
            RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                .fill(Color.primary.opacity(0.08))
                .padding(.horizontal, cr)
                .padding(.vertical, 5)
        }
    }
}

// MARK: - Panel Tab Button

private struct PanelTabButtonView: View {
    let mode: RightPanelMode
    let viewModel: DocumentViewModel

    @State private var isHovering = false

    private var isActive: Bool {
        viewModel.state.rightPanelMode == mode
    }

    private var fillOpacity: Double {
        if isActive { return 0.12 }
        if isHovering { return 0.07 }
        return 0
    }

    var body: some View {
        Button {
            if viewModel.state.rightPanelMode == mode {
                viewModel.state.rightPanelMode = nil
            } else {
                viewModel.state.rightPanelMode = mode
            }
        } label: {
            Image(systemName: mode.systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 26)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(fillOpacity))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .help(mode.label)
    }
}

// MARK: - Library Tab Button

private struct LibraryTabButtonView: View {
    let tab: LibraryDetailTab
    let appState: AppState

    @State private var isHovering = false

    private var isActive: Bool {
        appState.libraryDetailTab == tab
    }

    private var fillOpacity: Double {
        if isActive { return 0.12 }
        if isHovering { return 0.07 }
        return 0
    }

    var body: some View {
        Button {
            if appState.libraryDetailTab == tab {
                appState.libraryDetailTab = nil
            } else {
                appState.libraryDetailTab = tab
            }
        } label: {
            Image(systemName: tab.systemImage)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 34, height: 26)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(fillOpacity))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .help(tab.label)
    }
}

// MARK: - Glass Group Modifier

/// Wraps content in a Liquid Glass capsule on macOS 26+,
/// falling back to ultraThinMaterial + stroke on older systems.
private struct GlassGroupModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content
                .background(
                    .ultraThinMaterial,
                    in: Capsule()
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
        }
    }
}
