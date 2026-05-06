import SwiftUI

/// Unified settings view with left sidebar list navigation.
struct SettingsView: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, Identifiable {
        case general
        case library
        case ai
        case epub
        case plugins
        case youtube
        // Plugin tabs
        case pluginNotes
        case pluginTranslation
        case pluginGraphMap

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: return "General"
            case .library: return "Library"
            case .ai: return "AI"
            case .epub: return "EPUB"
            case .plugins: return "Plugins"
            case .youtube: return "YouTube"
            case .pluginNotes: return Plugin.notes.label
            case .pluginTranslation: return Plugin.translation.label
            case .pluginGraphMap: return Plugin.graphMap.label
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .library: return "books.vertical"
            case .ai: return "brain"
            case .epub: return "book.fill"
            case .plugins: return "puzzlepiece.extension"
            case .youtube: return "play.rectangle"
            case .pluginNotes: return Plugin.notes.systemImage
            case .pluginTranslation: return Plugin.translation.systemImage
            case .pluginGraphMap: return Plugin.graphMap.systemImage
            }
        }

        /// The plugin this tab belongs to, if any.
        var plugin: Plugin? {
            switch self {
            case .pluginNotes: return .notes
            case .pluginTranslation: return .translation
            case .pluginGraphMap: return .graphMap
            default: return nil
            }
        }

        static func tab(for plugin: Plugin) -> Tab {
            switch plugin {
            case .notes: return .pluginNotes
            case .translation: return .pluginTranslation
            case .graphMap: return .pluginGraphMap
            }
        }
    }

    /// Fixed tabs that always appear.
    private static let fixedTabs: [Tab] = [.general, .library, .ai, .epub, .plugins, .youtube]

    @State private var selectedTab: Tab = .general
    @State private var pluginRefresh = false

    private var visibleTabs: [Tab] {
        _ = pluginRefresh
        var tabs = Self.fixedTabs
        // Insert enabled plugin tabs after .plugins
        let pluginTabs = Plugin.allCases
            .filter { Preferences.shared.isPluginEnabled($0) }
            .map { Tab.tab(for: $0) }
        if let idx = tabs.firstIndex(of: .plugins) {
            tabs.insert(contentsOf: pluginTabs, at: idx + 1)
        }
        return tabs
    }

    var body: some View {
        NavigationSplitView {
            List(visibleTabs, selection: $selectedTab) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            settingsContent
                .navigationTitle(selectedTab.label)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
        }
        .frame(width: 780, height: 580)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // If current tab's plugin was disabled, fall back to .plugins
            if let plugin = selectedTab.plugin, !Preferences.shared.isPluginEnabled(plugin) {
                selectedTab = .plugins
            }
            pluginRefresh.toggle()
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
        case .epub:
            EPUBSettingsView()
        case .plugins:
            PluginSettingsView()
        case .youtube:
            YouTubeSettingsView()
        case .pluginNotes:
            NoteSettingsView()
        case .pluginTranslation:
            TranslationSettingsView()
        case .pluginGraphMap:
            GraphMapSettingsView()
        }
    }
}
