import SwiftUI

/// Unified settings view with left sidebar list navigation.
struct SettingsView: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, Identifiable {
        case general
        case library
        case ai
        case localModels
        case audio
        case characters
        case plugins
        case youtube
        // Plugin tabs
        case pluginNotes
        case pluginTranslation

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: return "General"
            case .library: return "Library"
            case .ai: return "AI Providers"
            case .localModels: return "Local Models"
            case .audio: return "Audio"
            case .characters: return "Characters"
            case .plugins: return "Plugins"
            case .youtube: return "YouTube"
            case .pluginNotes: return Plugin.notes.label
            case .pluginTranslation: return Plugin.translation.label
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .library: return "books.vertical"
            case .ai: return "sparkles.2"
            case .localModels: return "arrow.down.circle"
            case .audio: return "speaker.wave.2"
            case .characters: return "person.2"
            case .plugins: return "puzzlepiece.extension"
            case .youtube: return "play.rectangle"
            case .pluginNotes: return Plugin.notes.systemImage
            case .pluginTranslation: return Plugin.translation.systemImage
            }
        }

        /// The plugin this tab belongs to, if any.
        var plugin: Plugin? {
            switch self {
            case .pluginNotes: return .notes
            case .pluginTranslation: return .translation
            default: return nil
            }
        }

        static func tab(for plugin: Plugin) -> Tab {
            switch plugin {
            case .notes: return .pluginNotes
            case .translation: return .pluginTranslation
            }
        }
    }

    /// Fixed tabs that always appear.
    private static let fixedTabs: [Tab] = [.general, .library, .ai, .localModels, .audio, .characters, .plugins, .youtube]

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
        .frame(width: 900, height: 620)
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
            AIProvidersSettingsView()
        case .localModels:
            LocalModelsSettingsView()
        case .audio:
            AudioSettingsView()
        case .characters:
            CharacterSettingsView()
        case .plugins:
            PluginSettingsView()
        case .youtube:
            YouTubeSettingsView()
        case .pluginNotes:
            NoteSettingsView()
        case .pluginTranslation:
            TranslationSettingsView()
        }
    }
}
