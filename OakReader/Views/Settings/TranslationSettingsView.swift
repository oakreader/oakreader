import SwiftUI

struct TranslationSettingsView: View {
    @State private var sourceLang: TranslationLanguage
    @State private var targetLang: TranslationLanguage

    init() {
        let prefs = Preferences.shared
        _sourceLang = State(initialValue: prefs.translationSourceLang)
        _targetLang = State(initialValue: prefs.translationTargetLang)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                languageSection
                Spacer()
            }
            .padding(20)
        }
        .onDisappear {
            saveSettings()
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
                            Text(lang.nativeName).tag(lang)
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
                            Text(lang.nativeName).tag(lang)
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
        prefs.translationSourceLang = sourceLang
        prefs.translationTargetLang = targetLang
    }
}
