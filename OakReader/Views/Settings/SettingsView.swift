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
        case extensionQuizCards

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: return "General"
            case .library: return "Library"
            case .ai: return "AI"
            case .agent: return "Agent"
            case .audio: return "Audio"
            case .extensions: return "Extensions"
            case .skills: return "Skills"
            case .webSearch: return "Web Search"
            case .extensionTranslation: return AppExtension.translation.label
            case .extensionQuizCards: return AppExtension.quizCards.label
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .library: return "books.vertical"
            case .ai: return "sparkles.2"
            case .agent: return "wrench.and.screwdriver"
            case .audio: return "speaker.wave.2"
            case .extensions: return "square.grid.2x2"
            case .skills: return "hammer"
            case .webSearch: return "magnifyingglass.circle"
            case .extensionTranslation: return AppExtension.translation.systemImage
            case .extensionQuizCards: return AppExtension.quizCards.systemImage
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
            case .extensionQuizCards: return .quizCards
            default: return nil
            }
        }

        /// Tabs exposed in the command palette for deep-linking.
        static let paletteTabs: [Tab] = [.general, .library, .ai, .agent, .audio, .extensions, .webSearch]

        static func tab(for ext: AppExtension) -> Tab {
            switch ext {
            case .translation: return .extensionTranslation
            case .quizCards: return .extensionQuizCards
            }
        }
    }

    /// Fixed tabs that always appear.
    private static let fixedTabs: [Tab] = [.general, .library, .ai, .agent, .audio, .skills, .extensions, .webSearch]

    @State private var selectedTab: Tab = .general
    @State private var visibleTabs: [Tab] = Self.buildVisibleTabs()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    private static func buildVisibleTabs() -> [Tab] {
        var tabs = fixedTabs
        let pluginTabs = AppExtension.allCases
            .filter { Preferences.shared.isExtensionEnabled($0) }
            .map { Tab.tab(for: $0) }
        if let idx = tabs.firstIndex(of: .extensions) {
            tabs.insert(contentsOf: pluginTabs, at: idx + 1)
        }
        return tabs
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(visibleTabs, selection: $selectedTab) { tab in
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
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
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
            let updated = Self.buildVisibleTabs()
            if visibleTabs != updated {
                if let ext = selectedTab.appExtension, !Preferences.shared.isExtensionEnabled(ext) {
                    selectedTab = .extensions
                }
                visibleTabs = updated
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
            TranslationSettingsView()
        case .extensionQuizCards:
            QuizCardSettingsView()
        }
    }
}
