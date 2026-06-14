import SwiftUI

struct TabBarView: View {
    let appState: AppState

    // Leave space for macOS traffic light buttons (close/minimize/zoom)
    private let trafficLightPadding: CGFloat = 80
    private let fullScreenPadding: CGFloat = 8

    @State private var isFullScreen = false
    @State private var isPinnedHovering = false
    @State private var isAgentHovering = false
    @State private var isAgentCloseHovering = false
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
                appState.showLibraryBrowse()
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
                .frame(width: OakStyle.Size.tabMax, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(appState.isLibraryBrowseActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
            .background(pinnedTabShape)
            .onHover { isPinnedHovering = $0 }
            .help("Library: \(pinnedTabTitle)")
            .padding(.trailing, 4)

            // Agent workspace pill (closeable; shown once opened).
            // Matches the Library pinned tab's metrics; close button overlays the
            // trailing edge so the pill width stays consistent with its sibling.
            if appState.isAgentTabOpen {
                HStack(spacing: 6) {
                    OakAppIcon(size: OakStyle.Font.icon)
                    Text("Agent")
                        .font(OakStyle.Font.styled(size: OakStyle.Font.body, weight: .regular))
                        .lineLimit(1)
                }
                .padding(.leading, 16)
                .padding(.trailing, 20)
                .frame(height: OakStyle.Size.tabHeight)
                .frame(width: OakStyle.Size.tabMax, alignment: .leading)
                .foregroundStyle(appState.isAgentActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
                .background(agentPillShape)
                .overlay(alignment: .trailing) {
                    Button {
                        appState.closeAgentWorkspace()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isAgentCloseHovering ? Color(nsColor: .labelColor) : .secondary)
                            .frame(width: OakStyle.Size.closeButton, height: OakStyle.Size.closeButton)
                            .background(
                                RoundedRectangle(cornerRadius: OakStyle.Radius.small)
                                    .fill(isAgentCloseHovering ? Color.primary.opacity(0.1) : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isAgentCloseHovering = $0 }
                    .opacity(appState.isAgentActive || isAgentHovering ? 1 : 0)
                    .padding(.trailing, 4)
                    .accessibilityLabel("Close Agent")
                }
                .contentShape(Rectangle())
                .onTapGesture { appState.openAgentWorkspace() }
                .onHover { isAgentHovering = $0 }
                .help("AI Agent workspace")
            }

            // Document tabs share the strip width equally (Chrome-style): each tab
            // divides the available space, capped at `tabMax` and floored at `tabMin`,
            // scrolling only when even the floor overflows. The trailing "+" (Dia-style
            // router) stays adjacent to the last tab; the strip's fill pushes the
            // right-hand panel controls to the trailing edge.
            DocumentTabStrip(appState: appState)
                .frame(maxWidth: .infinity)

            // Panel mode tabs — context-dependent. Live browser tabs have no
            // storage key but still support chat/translation/cards panels.
            if let viewModel = appState.activeTab?.viewModel,
               viewModel.storageKey != nil || viewModel.liveURL != nil,
               !viewModel.state.isZenMode {
                // Document tab: show document panel modes
                HStack(spacing: 4) {
                    ForEach(panelVisibleModes) { mode in
                        panelTabButton(mode: mode, viewModel: viewModel)
                    }
                }
                .padding(.trailing, 4)
            } else if appState.isLibraryBrowseActive {
                // Library browser: show library detail tabs
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
        PillTabButton(
            systemImage: mode.systemImage,
            label: mode.label,
            isActive: viewModel.state.rightPanelMode == mode
        ) {
            viewModel.state.rightPanelMode = viewModel.state.rightPanelMode == mode ? nil : mode
        }
    }

    // MARK: - Library Detail Tabs

    private func libraryTabButton(tab: LibraryDetailTab) -> some View {
        PillTabButton(
            systemImage: tab.systemImage,
            label: tab.label,
            isActive: appState.libraryDetailTab == tab
        ) {
            appState.libraryDetailTab = appState.libraryDetailTab == tab ? nil : tab
        }
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
        if appState.isLibraryBrowseActive {
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

    @ViewBuilder
    private var agentPillShape: some View {
        if appState.isAgentActive {
            RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                .fill(OakStyle.Colors.activeTabBackground)
                .padding(.vertical, 6)
        } else if isAgentHovering {
            RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                .fill(Color.primary.opacity(0.08))
                .padding(.vertical, 6)
        }
    }
}

// MARK: - Document Tab Strip

/// Chrome-style equal-width tab strip. Every document (and quiz) tab shares the
/// available width equally — `clamp(available / count, tabMin, tabMax)` — so a few
/// tabs sit at `tabMax` (uniform, with trailing space) and shrink together as more
/// open. Only when even `tabMin` overflows does the strip fall back to scrolling.
/// The trailing "+" router stays adjacent to the last tab.
private struct DocumentTabStrip: View {
    let appState: AppState

    private let cr: CGFloat = 10           // concave radius (matches DocumentTabView)
    private let plusWidth: CGFloat = 40    // "+" button + its horizontal padding

    private var tabCount: Int {
        appState.openTabs.count
    }

    var body: some View {
        let maxW = OakStyle.Size.tabMax + cr * 2
        let minW = OakStyle.Size.tabMin + cr * 2

        GeometryReader { geo in
            let available = max(0, geo.size.width - plusWidth)
            let ideal = tabCount > 0 ? available / CGFloat(tabCount) : maxW
            let width = min(maxW, max(minW, ideal))
            let fits = CGFloat(tabCount) * minW <= available + 0.5

            if fits {
                row(width: width)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    row(width: minW)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func row(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(appState.openTabs.enumerated()), id: \.element.id) { index, tab in
                DocumentTabView(
                    tab: tab,
                    isActive: tab.id == appState.activeTabID,
                    isFirst: index == 0,
                    width: width,
                    onSelect: { appState.switchToTab(tab.id) },
                    onClose: { appState.closeTab(tab.id) }
                )
            }

            // New tab router (navigate / search / ask) — sits at the end of the strip.
            Button {
                appState.openNewTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
            .help("New Tab")
            .accessibilityLabel("New Tab")
            .padding(.leading, 4)
            .padding(.trailing, 8)

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Pill Tab Button

/// A row of these renders the right-hand title-bar panel tabs (AI Chat / Metadata
/// / Translation / Quiz Cards) and the library detail tabs. The *active* button
/// expands into a capsule that reveals its text label; inactive ones stay
/// icon-only.
///
/// Why the label is **always** in the view tree (never `if isActive { Text }`):
/// conditionally inserting/removing the label drives SwiftUI's `.transition`
/// machinery, which gave us two bugs that no amount of duration-tuning fixed —
///  1. **double-image / "ghost"**: switching A→B cross-fades A's *removal* with
///     B's *insertion*, so two labels are briefly on screen at once.
///  2. **flash**: gating the incoming label with a delayed `.transition`
///     animation makes SwiftUI pop it to its final state for one frame (a known
///     insertion-transition quirk — see forums.swift.org/t/.../42211).
///
/// Instead the label is permanent and we animate its *width* and *opacity* as
/// continuous properties. The incoming label's animation is delayed by ~= the
/// outgoing label's collapse time, so the old one is fully gone before the new
/// one starts (no overlap) — and because the delay sits on a property animation
/// rather than a `.transition`, it does NOT trigger the insertion pop. The
/// label's natural width is measured once via a preference so the frame can
/// animate 0 ↔ width without an identity change.
private struct PillTabButton: View {
    let systemImage: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    @State private var isHovering = false
    @State private var labelWidth: CGFloat = 0

    private var fillOpacity: Double {
        if isActive { return 0.12 }
        if isHovering { return 0.07 }
        return 0
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize()
                    .padding(.leading, 5)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: TabLabelWidthKey.self, value: proxy.size.width)
                        }
                    )
                    .frame(width: isActive ? labelWidth : 0, alignment: .leading)
                    .opacity(isActive ? 1 : 0)
                    .clipped()
            }
            .frame(height: 26)
            .padding(.leading, 9)
            .padding(.trailing, isActive ? 10 : 9)
            .frame(minWidth: 34, alignment: .leading)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(fillOpacity))
            )
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
        .onHover { isHovering = $0 }
        .onPreferenceChange(TabLabelWidthKey.self) { labelWidth = $0 }
        // Asymmetric, bounce-0: fast collapse (0.12), and an expand that is
        // *delayed* by ~= the collapse time so the outgoing label clears first.
        // The delay is safe here only because it sits on property animations
        // (width/opacity), not on a `.transition` — see the type doc above.
        .animation(isActive ? .smooth(duration: 0.3).delay(0.13) : .smooth(duration: 0.12), value: isActive)
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .help(label)
    }
}

/// Measures a pill tab's natural (expanded) label width so it can animate
/// between 0 and that width without inserting/removing the label.
private struct TabLabelWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

