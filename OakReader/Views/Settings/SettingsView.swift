import SwiftUI
import OakVoiceAI

/// Unified settings view with left sidebar list navigation.
struct SettingsView: View {
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    enum Tab: String, Identifiable {
        case general
        case library
        case ai
        case aiSettings
        case localModels
        case audio
        case characters
        case extensions
        case skills
        case youtube
        // Extension tabs
        case extensionNotes
        case extensionTranslation

        var id: String { rawValue }

        var label: String {
            switch self {
            case .general: return "General"
            case .library: return "Library"
            case .ai: return "AI Providers"
            case .aiSettings: return "AI Settings"
            case .localModels: return "Local Models"
            case .audio: return "Audio"
            case .characters: return "Characters"
            case .extensions: return "Extensions"
            case .skills: return "Skills"
            case .youtube: return "YouTube"
            case .extensionNotes: return AppExtension.notes.label
            case .extensionTranslation: return AppExtension.translation.label
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .library: return "books.vertical"
            case .ai: return "sparkles.2"
            case .aiSettings: return "cpu"
            case .localModels: return "arrow.down.circle"
            case .audio: return "speaker.wave.2"
            case .characters: return "person.2"
            case .extensions: return "square.grid.2x2"
            case .skills: return "hammer"
            case .youtube: return "play.rectangle"
            case .extensionNotes: return AppExtension.notes.systemImage
            case .extensionTranslation: return AppExtension.translation.systemImage
            }
        }

        /// The app extension this tab belongs to, if any.
        var appExtension: AppExtension? {
            switch self {
            case .extensionNotes: return .notes
            case .extensionTranslation: return .translation
            default: return nil
            }
        }

        static func tab(for ext: AppExtension) -> Tab {
            switch ext {
            case .notes: return .extensionNotes
            case .translation: return .extensionTranslation
            }
        }
    }

    /// Fixed tabs that always appear.
    private static let fixedTabs: [Tab] = [.general, .library, .ai, .aiSettings, .audio, .skills, .characters, .extensions, .youtube]

    @State private var selectedTab: Tab = .general
    @State private var visibleTabs: [Tab] = Self.buildVisibleTabs()
    @State private var modelStates = SharedModelStates()

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
        NavigationSplitView {
            List(visibleTabs, selection: $selectedTab) { tab in
                Label(tab.label, systemImage: tab.icon)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            settingsContent
                .id(selectedTab)
                .transition(.identity)
                .navigationTitle(selectedTab.label)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
        }
        .animation(.none, value: selectedTab)
        .frame(width: 900, height: 620)
        .onReceive(NotificationCenter.default.publisher(for: Preferences.appExtensionToggleNotification)) { _ in
            let updated = Self.buildVisibleTabs()
            if visibleTabs != updated {
                if let ext = selectedTab.appExtension, !Preferences.shared.isExtensionEnabled(ext) {
                    selectedTab = .extensions
                }
                visibleTabs = updated
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
            AIProvidersSettingsView(modelStates: modelStates)
        case .aiSettings:
            AISettingsView(modelStates: modelStates)
        case .localModels:
            EmptyView() // Moved under AI Providers
        case .audio:
            AudioSettingsView()
        case .characters:
            CharacterSettingsView(database: store.database)
        case .extensions:
            AppExtensionSettingsView()
        case .skills:
            SkillManagementView()
        case .youtube:
            YouTubeSettingsView()
        case .extensionNotes:
            NoteSettingsView()
        case .extensionTranslation:
            TranslationSettingsView()
        }
    }
}

// MARK: - Shared Model States

/// Shared model download state observer, used by AISettingsView and LocalModelsSettingsView
/// so only one observation loop runs regardless of which tab is active.
@Observable
final class SharedModelStates {
    var states: [String: ModelManager.ModelState] = [:]
    private var observeTask: Task<Void, Never>?
    private var isObserving = false

    func startIfNeeded() {
        guard !isObserving else { return }
        isObserving = true
        observeTask = Task { [weak self] in
            for await (repo, state) in ModelManager.shared.stateChanges {
                await MainActor.run { self?.states[repo] = state }
            }
        }
    }

    func refresh(repos: [String]) {
        startIfNeeded()
        Task {
            for repo in repos {
                let state = await ModelManager.shared.state(for: repo)
                await MainActor.run { self.states[repo] = state }
            }
        }
    }

    deinit {
        observeTask?.cancel()
    }
}
