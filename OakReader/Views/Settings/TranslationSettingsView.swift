import SwiftUI
import OakAgent

struct TranslationSettingsView: View {
    @State private var sourceLang: TranslationLanguage
    @State private var targetLang: TranslationLanguage

    // Translation LLM
    @State private var translationUseChatDefault: Bool
    @State private var translationProviderId: String
    @State private var translationModel: String

    private let store = ConfiguredProviderStore.shared

    init() {
        let prefs = Preferences.shared
        let defaults = UserDefaults.standard

        _sourceLang = State(initialValue: prefs.translationSourceLang)
        _targetLang = State(initialValue: prefs.translationTargetLang)

        // Translation LLM – nil raw key means "use chat default"
        let translationRaw = defaults.string(forKey: "translationAIProvider")
        _translationUseChatDefault = State(initialValue: translationRaw == nil)
        _translationProviderId = State(initialValue: prefs.translationAIProviderId)
        let tm = prefs.translationAIModel
        _translationModel = State(initialValue: tm.isEmpty
            ? (ProviderRegistry.shared.provider(for: prefs.translationAIProviderId)?.defaultModelId ?? "") : tm)
    }

    var body: some View {
        Form {
            languageSection
            llmSection
        }
        .formStyle(.grouped)
        .onDisappear { saveLLM() }
    }

    // MARK: - Default Languages Section

    private var languageSection: some View {
        Section {
            Picker("Source Language", selection: $sourceLang) {
                ForEach(TranslationLanguage.allCases) { language in
                    Text(language.nativeName).tag(language)
                }
            }
            .onChange(of: sourceLang) { _, newValue in
                Preferences.shared.translationSourceLang = newValue
            }

            Picker("Target Language", selection: $targetLang) {
                ForEach(TranslationLanguage.targetCases) { language in
                    Text(language.nativeName).tag(language)
                }
            }
            .onChange(of: targetLang) { _, newValue in
                Preferences.shared.translationTargetLang = newValue
            }
        } header: {
            Text("Default Languages")
        } footer: {
            Text("Used by the translation panel when selected text is sent for translation.")
        }
    }

    // MARK: - LLM Section

    private var llmSection: some View {
        Section("Translation LLM") {
            Toggle("Use Chat default", isOn: $translationUseChatDefault)

            if translationUseChatDefault {
                chatDefaultLabel
            } else {
                llmPickers
            }
        }
    }

    @ViewBuilder
    private var llmPickers: some View {
        if store.configuredLLMProviders.isEmpty {
            Text("Configure a provider in AI Providers first.")
                .foregroundStyle(.secondary)
        } else {
            Picker("Provider", selection: $translationProviderId) {
                ForEach(store.configuredLLMProviders) { p in
                    Text(p.displayName).tag(p.id)
                }
            }
            .onChange(of: translationProviderId) { _, newValue in
                translationModel = ProviderRegistry.shared.provider(for: newValue)?.defaultModelId ?? ""
            }

            if let provider = ProviderRegistry.shared.provider(for: translationProviderId) {
                Picker("Model", selection: $translationModel) {
                    ForEach(provider.models) { m in
                        Text(m.name).tag(m.id)
                    }
                }
            }
        }
    }

    private var chatDefaultLabel: some View {
        let prefs = Preferences.shared
        let pid = prefs.aiProviderId
        let model = prefs.aiModel
        let providerName = ProviderRegistry.shared.provider(for: pid)?.displayName ?? pid
        let modelName = ProviderRegistry.shared.provider(for: pid)?.models.first(where: { $0.id == model })?.name ?? model
        return LabeledContent("Using", value: "\(providerName) / \(modelName)")
            .foregroundStyle(.secondary)
    }

    // MARK: - Save

    private func saveLLM() {
        let prefs = Preferences.shared
        let defaults = UserDefaults.standard

        if translationUseChatDefault {
            defaults.removeObject(forKey: "translationAIProvider")
            defaults.removeObject(forKey: "translationAIModel")
        } else {
            prefs.translationAIProviderId = translationProviderId
            prefs.translationAIModel = translationModel
        }
    }
}
