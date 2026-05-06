import Foundation
import OakReaderAI

@Observable
class TranslationViewModel {
    weak var parent: DocumentViewModel?

    var sourceText: String = ""
    var translatedText: String = ""
    var sourceLang: TranslationLanguage
    var targetLang: TranslationLanguage
    var isTranslating: Bool = false
    var errorMessage: String?

    private var streamTask: Task<Void, Never>?
    private let router = ProviderRouter()

    init(parent: DocumentViewModel) {
        self.parent = parent
        let prefs = Preferences.shared
        self.sourceLang = prefs.translationSourceLang
        self.targetLang = prefs.translationTargetLang
    }

    // MARK: - Public API

    /// Called from text selection popup — sets source text and auto-triggers translation.
    func setSourceText(_ text: String) {
        sourceText = text
        translate()
    }

    func translate() {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        stopTranslation()
        translatedText = ""
        errorMessage = nil
        isTranslating = true

        let prefs = Preferences.shared
        let pid = prefs.translationAIProviderId
        let model: String = {
            let m = prefs.translationAIModel
            return m.isEmpty ? (ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? "") : m
        }()

        let sameLanguage = sourceLang == targetLang && sourceLang != .auto
        let systemPrompt = sameLanguage
            ? "You are a text polishing engine. Revise the text to improve clarity, conciseness, and readability. Output only the revised text without explanations."
            : "You are a translation engine that translates text accurately and naturally. Output only the translated text without explanations."

        let userPrompt: String
        if sameLanguage {
            userPrompt = "Polish the following text in \(targetLang.displayName):\n\n\(text)"
        } else {
            let sourceLabel = sourceLang == .auto ? "auto-detected language" : sourceLang.displayName
            userPrompt = "Translate from \(sourceLabel) to \(targetLang.displayName):\n\n\(text)"
        }

        let config = ProviderConfig(providerId: pid, model: model)
        let messages = [LLMMessage(role: .user, text: userPrompt)]

        streamTask = Task { @MainActor in
            do {
                let svc = try router.provider(for: config)
                let stream = svc.sendMessage(
                    messages: messages,
                    model: model,
                    systemPrompt: systemPrompt,
                    maxTokens: 4096
                )

                for try await chunk in stream {
                    switch chunk {
                    case .delta(let delta):
                        translatedText += delta
                    case .toolUse:
                        break
                    case .finished:
                        break
                    case .error(let msg):
                        errorMessage = msg
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                }
            }
            isTranslating = false
        }
    }

    func stopTranslation() {
        streamTask?.cancel()
        streamTask = nil
        isTranslating = false
    }

    func clear() {
        stopTranslation()
        sourceText = ""
        translatedText = ""
        errorMessage = nil
    }

    func swapLanguages() {
        guard sourceLang != .auto else { return }
        let temp = sourceLang
        sourceLang = targetLang
        targetLang = temp
        persistLanguages()

        if !translatedText.isEmpty {
            sourceText = translatedText
            translate()
        }
    }

    func onLanguageChange() {
        persistLanguages()
        if !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            translate()
        }
    }

    // MARK: - Private

    private func persistLanguages() {
        let prefs = Preferences.shared
        prefs.translationSourceLang = sourceLang
        prefs.translationTargetLang = targetLang
    }
}
