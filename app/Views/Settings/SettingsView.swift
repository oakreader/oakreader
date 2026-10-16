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
        case extensionQuickChatSkills

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
            case .extensionQuickChatSkills: return AppExtension.quickChat.label
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .library: return "books.vertical"
            case .ai: return "sparkles"
            case .agent: return "point.3.connected.trianglepath.dotted"
            case .audio: return "speaker.wave.2"
            case .extensions: return "puzzlepiece.extension"
            case .skills: return "hammer"
            case .webSearch: return "globe"
            case .extensionTranslation: return AppExtension.translation.systemImage
            case .extensionQuickChatSkills: return AppExtension.quickChat.systemImage
            }
        }

        /// The filled glyph the settings sidebar draws. `icon` stays the outline
        /// form for the command palette, which sits among outline symbols.
        var sidebarSymbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .library: return "books.vertical.fill"
            case .ai: return "cpu.fill"
            case .agent: return "brain.head.profile.fill"
            case .audio: return "speaker.wave.2.fill"
            case .extensions: return "puzzlepiece.extension.fill"
            case .skills: return "hammer.fill"
            case .webSearch: return "globe.americas.fill"
            case .extensionTranslation, .extensionQuickChatSkills: return icon
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
            case .extensionQuickChatSkills: return .quickChat
            default: return nil
            }
        }

        /// Whether the page stays built, hidden, once left. A page with its
        /// own `NavigationStack` cannot: its stack keeps setting the window
        /// title while hidden, so the LLM page's title showed over every other
        /// page. It is rebuilt each time instead, as every page used to be.
        var staysBuilt: Bool { self != .ai }

        /// Tabs exposed in the command palette for deep-linking.
        static let paletteTabs: [Tab] = [.general, .library, .ai, .agent, .audio, .extensions, .webSearch]

        /// The dedicated settings pane for an extension, if it has one. Extensions
        /// without their own settings (e.g. Notes) return nil — they appear as a
        /// toggle in the Extensions list but add no sidebar sub-pane.
        static func tab(for ext: AppExtension) -> Tab? {
            switch ext {
            case .translation: return .extensionTranslation
            case .notes: return nil
            case .quickChat: return .extensionQuickChatSkills
            }
        }
    }

    @State private var selectedTab: Tab = .general
    @State private var pluginTabs: [Tab] = Self.enabledPluginTabs()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Every page opened since the window did. Each stays built once opened.
    @State private var builtTabs: [Tab] = [.general]

    /// Extension panes that are currently enabled (shown under the Extensions group).
    private static func enabledPluginTabs() -> [Tab] {
        AppExtension.allCases
            .filter { Preferences.shared.isExtensionEnabled($0) }
            .compactMap { Tab.tab(for: $0) }
    }

    private var sidebarGroups: [SettingsSidebar.Group] {
        [
            .init(title: nil, tabs: [.general, .library]),
            .init(title: "Models", tabs: [.ai, .audio]),
            .init(title: "Agent", tabs: [.agent, .skills, .webSearch]),
            .init(title: "Extensions", tabs: [.extensions] + pluginTabs),
        ]
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebar(groups: sidebarGroups, selection: $selectedTab)
                .navigationSplitViewColumnWidth(min: 175, ideal: 195, max: 215)
        } detail: {
            // Pages are kept, not rebuilt: switching only changes which one is
            // visible. Obry's settings do the same (`SettingsKeptPage`), and it
            // is what lets a page keep its scroll position and lets the switch
            // be a cross-fade instead of a cut.
            ZStack(alignment: .topLeading) {
                ForEach(builtTabs) { tab in
                    let isShown = tab == selectedTab
                    page(for: tab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .opacity(isShown ? 1 : 0)
                        .allowsHitTesting(isShown)
                        .accessibilityHidden(!isShown)
                        .environment(\.settingsPageIsShown, isShown)
                }
            }
            .animation(OakStyle.Motion.fade, value: selectedTab)
            .navigationTitle(selectedTab.label)
            // Page actions live here, keyed on the selection, not inside the
            // pages: a kept page's own toolbar would stay up while it is hidden.
            .toolbar {
                if selectedTab == .skills {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            SkillManagementView.openSkillsFolder()
                        } label: {
                            Label("Open Folder", systemImage: "folder")
                                .labelStyle(.titleAndIcon)
                        }
                        .help("Show installed skills in Finder")
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .onChange(of: columnVisibility) { _, _ in
            // Prevent sidebar from being collapsed
            columnVisibility = .all
        }
        .onChange(of: selectedTab) { old, tab in
            if !old.staysBuilt { builtTabs.removeAll { $0 == old } }
            if !builtTabs.contains(tab) { builtTabs.append(tab) }
        }
        .frame(minWidth: 900, minHeight: 620)
        .onReceive(NotificationCenter.default.publisher(for: Preferences.appExtensionToggleNotification)) { _ in
            let updated = Self.enabledPluginTabs()
            if pluginTabs != updated {
                if let ext = selectedTab.appExtension, !Preferences.shared.isExtensionEnabled(ext) {
                    selectedTab = .extensions
                }
                pluginTabs = updated
                // A disabled extension's page must not stay built behind the others.
                builtTabs.removeAll { $0.appExtension != nil && !updated.contains($0) }
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
    private func page(for tab: Tab) -> some View {
        switch tab {
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
        case .extensionQuickChatSkills:
            QuickChatSettingsView()
        }
    }
}
