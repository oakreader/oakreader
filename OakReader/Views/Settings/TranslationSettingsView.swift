import SwiftUI
import OakReaderAI

struct TranslationSettingsView: View {
    @State private var translationProvider: AIProvider
    @State private var translationModel: String
    @State private var sourceLang: TranslationLanguage
    @State private var targetLang: TranslationLanguage
    @State private var testResult: String?
    @State private var isTesting = false

    init() {
        let prefs = Preferences.shared
        _translationProvider = State(initialValue: prefs.translationAIProvider)
        _translationModel = State(initialValue: {
            let m = prefs.translationAIModel
            return m.isEmpty ? prefs.translationAIProvider.defaultModel : m
        }())
        _sourceLang = State(initialValue: prefs.translationSourceLang)
        _targetLang = State(initialValue: prefs.translationTargetLang)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                aiSection
                Divider()
                languageSection
                Spacer()
            }
            .padding(20)
        }
        .onDisappear {
            saveSettings()
        }
    }

    // MARK: - AI Provider Section

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI Provider")
                .font(.system(size: 13, weight: .bold))

            Text("Select the AI provider and model used for translation.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Provider")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("Provider", selection: $translationProvider) {
                        ForEach(AIProvider.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)
                    .onChange(of: translationProvider) { _, newValue in
                        translationModel = newValue.defaultModel
                        testResult = nil
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Model")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("Model", selection: $translationModel) {
                        ForEach(translationProvider.models) { m in
                            Text(m.name).tag(m.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            HStack(spacing: 6) {
                if let key = KeychainService.apiKey(for: translationProvider), !key.isEmpty {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("API key configured")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Configure API key in AI settings")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer().frame(width: 8)

                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Testing...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Button("Test Connection") { testConnection() }
                        .controlSize(.small)
                        .disabled(KeychainService.apiKey(for: translationProvider) == nil)
                }

                if let result = testResult {
                    Text(result)
                        .font(.system(size: 11))
                        .foregroundStyle(result.contains("Success") ? .green : .red)
                }
            }
        }
    }

    // MARK: - Default Languages Section

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Default Languages")
                .font(.system(size: 13, weight: .bold))

            Text("Default source and target languages for the translation panel.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source Language")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("Source", selection: $sourceLang) {
                        ForEach(TranslationLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Target Language")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Picker("Target", selection: $targetLang) {
                        ForEach(TranslationLanguage.targetCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }
        }
    }

    // MARK: - Helpers

    private func saveSettings() {
        let prefs = Preferences.shared
        prefs.translationAIProvider = translationProvider
        prefs.translationAIModel = translationModel
        prefs.translationSourceLang = sourceLang
        prefs.translationTargetLang = targetLang
    }

    private func testConnection() {
        saveSettings()
        isTesting = true
        testResult = nil

        Task {
            do {
                let router = ProviderRouter()
                let config = ProviderConfig(provider: translationProvider, model: translationModel)
                let svc = try router.provider(for: config)
                let messages = [LLMMessage(role: .user, text: "Say 'OK' and nothing else.")]
                let stream = svc.sendMessage(
                    messages: messages, model: translationModel,
                    systemPrompt: nil, maxTokens: 50
                )
                var gotDelta = false
                for try await chunk in stream {
                    if case .delta = chunk { gotDelta = true; break }
                }
                await MainActor.run {
                    testResult = gotDelta ? "Success!" : "No response received"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "Error: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}
