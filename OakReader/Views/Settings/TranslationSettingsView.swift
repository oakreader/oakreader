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
        Form {
            languageSection
        }
        .formStyle(.grouped)
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
}
