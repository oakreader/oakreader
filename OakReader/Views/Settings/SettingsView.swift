import SwiftUI
import OakVoice

/// Unified settings view with left sidebar list navigation.
struct SettingsView: View {
    let store: LibraryStore

    enum Tab: String, Identifiable {
        case general
        case library
        case ai
        case agent
        case audio
        case extensions
        case skills
        case webSearch
        // Extension tabs
        case extensionTranslation

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: return "General"
            case .library: return "Library"
            case .ai: return "LLM"
            case .agent: return "Agent"
            case .audio: return "Audio"
            case .extensions: return "Extensions"
            case .skills: return "Skills"
            case .webSearch: return "Web Search"
            case .extensionTranslation: return AppExtension.translation.label
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .library: return "books.vertical"
            case .ai: return "cpu"
            case .agent: return "wrench.and.screwdriver"
            case .audio: return "speaker.wave.2"
            case .extensions: return "puzzlepiece.extension"
            case .skills: return "hammer"
            case .webSearch: return "magnifyingglass.circle"
            case .extensionTranslation: return AppExtension.translation.systemImage
            }
        }

        /// Custom icon asset name from the extension, if any.
        var iconAsset: String? {
            appExtension?.iconAsset
        }

        /// The app extension this tab belongs to, if any.
        var appExtension: AppExtension? {
            switch self {
            case .extensionTranslation: return .translation
            default: return nil
            }
        }

        /// Tabs exposed in the command palette for deep-linking.
        static let paletteTabs: [Tab] = [.general, .library, .ai, .agent, .audio, .extensions, .webSearch]

        static func tab(for ext: AppExtension) -> Tab {
            switch ext {
            case .translation: return .extensionTranslation
            }
        }
    }

    @State private var selectedTab: Tab = .general
    @State private var pluginTabs: [Tab] = Self.enabledPluginTabs()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Extension panes that are currently enabled (shown under the Extensions group).
    private static func enabledPluginTabs() -> [Tab] {
        AppExtension.allCases
            .filter { Preferences.shared.isExtensionEnabled($0) }
            .map { Tab.tab(for: $0) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selectedTab) {
                Section {
                    tabRow(.general)
                    tabRow(.library)
                }

                Section("Models") {
                    tabRow(.ai)
                    tabRow(.audio)
                }

                Section("Agent") {
                    tabRow(.agent)
                    tabRow(.skills)
                    tabRow(.webSearch)
                }

                Section("Extensions") {
                    tabRow(.extensions)
                    ForEach(pluginTabs) { tabRow($0) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 175, ideal: 195, max: 215)
        } detail: {
            settingsContent
                .id(selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle(selectedTab.label)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .onChange(of: columnVisibility) { _, _ in
            // Prevent sidebar from being collapsed
            columnVisibility = .all
        }
        .frame(minWidth: 900, minHeight: 620)
        .onReceive(NotificationCenter.default.publisher(for: Preferences.appExtensionToggleNotification)) { _ in
            let updated = Self.enabledPluginTabs()
            if pluginTabs != updated {
                if let ext = selectedTab.appExtension, !Preferences.shared.isExtensionEnabled(ext) {
                    selectedTab = .extensions
                }
                pluginTabs = updated
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsNavigateToTab)) { notification in
            if let tabId = notification.userInfo?["tab"] as? String,
               let tab = Tab(rawValue: tabId) {
                selectedTab = tab
            }
        }
    }

    @ViewBuilder
    private func tabRow(_ tab: Tab) -> some View {
        Label {
            Text(tab.label)
        } icon: {
            if let asset = tab.iconAsset {
                Image(asset)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: tab.icon)
            }
        }
        .tag(tab)
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsView()
        case .library:
            LibrarySettingsView(store: store)
        case .ai:
            AISettingsView()
        case .agent:
            AgentSettingsView()
        case .audio:
            AudioSettingsView()
        case .extensions:
            AppExtensionSettingsView()
        case .skills:
            SkillManagementView()
        case .webSearch:
            WebSearchSettingsView()
        case .extensionTranslation:
            TranslationSettingsView(store: store)
        }
    }
}
