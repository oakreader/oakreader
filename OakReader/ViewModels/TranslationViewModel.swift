import Foundation
import OakAgent

@Observable
class TranslationViewModel {
    weak var parent: DocumentViewModel?

    var sourceText: String = ""
    var translatedText: String = ""
    var sourceLang: TranslationLanguage
    var targetLang: TranslationLanguage
    var isTranslating: Bool = false
    var errorMessage: String?

    // Word explanation state
    var wordExplanation: String = ""
    var isExplainingWord: Bool = false
    var explanationWord: String = ""

    private var streamTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var wordExplanationTask: Task<Void, Never>?
    private var skipNextDebounce = false
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
        skipNextDebounce = true
        sourceText = Self.normalizeExtractedText(text)
        translate()
    }

    /// PDF text extraction carries hard line breaks (and hyphenated word
    /// splits) mid-sentence; collapse them so the source reads as prose.
    /// Blank lines (real paragraph breaks) are preserved, and CJK lines are
    /// joined without inserting spaces.
    private static func normalizeExtractedText(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "-\n", with: "")
        t = t.replacingOccurrences(
            of: "(?<=\\p{Han})\\n(?=\\p{Han})", with: "", options: .regularExpression
        )
        t = t.replacingOccurrences(
            of: "(?<!\\n)\\n(?!\\n)", with: " ", options: .regularExpression
        )
        t = t.replacingOccurrences(
            of: "[ \\t]{2,}", with: " ", options: .regularExpression
        )
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Called when the user types in the source text editor (debounced).
    func debouncedTranslate() {
        if skipNextDebounce {
            skipNextDebounce = false
            return
        }
        debounceTask?.cancel()
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            stopTranslation()
            translatedText = ""
            errorMessage = nil
            return
        }
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            translate()
        }
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

        let (systemPrompt, userPrompt) = buildPrompts(text: text)

        let config = ProviderConfig(providerId: pid, model: model)
        let messages = [LLMMessage(role: .user, text: userPrompt)]

        streamTask = Task { @MainActor in
            do {
                let svc = try await router.provider(for: config)
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
                    case .thinking:
                        break
                    case .toolUse, .toolInputDelta:
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

    // MARK: - Prompt Construction

    private var isChinese: Bool {
        [.zhHans, .zhHant, .lzh].contains(targetLang)
    }

    /// Detect whether the input is a single word or short phrase suitable for dictionary-style output.
    private func isWordLookup(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        // Single English-style word, or a very short CJK string (≤4 chars with no spaces)
        if words.count == 1 && text.count <= 30 { return true }
        // Short CJK input (no spaces, ≤5 chars) — likely a word/phrase lookup
        if words.count == 1 && text.count <= 5
            && text.unicodeScalars.contains(where: { $0.value >= 0x4E00 && $0.value <= 0x9FFF }) {
            return true
        }
        return false
    }

    /// Build document context string from the parent document's metadata.
    private var documentContext: String {
        guard let item = parent?.libraryItem else { return "" }
        var parts: [String] = []
        if !item.title.isEmpty { parts.append("Document: \(item.title)") }
        if !item.author.isEmpty { parts.append("Author: \(item.author)") }
        parts.append("Type: \(item.contentType.rawValue)")
        return parts.joined(separator: " | ")
    }

    private func buildPrompts(text: String) -> (system: String, user: String) {
        let sameLanguage = sourceLang == targetLang && sourceLang != .auto
        let sourceLabel = sourceLang == .auto ? "auto-detected language" : sourceLang.displayName
        let targetLabel = targetLang.displayName
        let docCtx = documentContext

        // --- Polishing mode (same language) ---
        if sameLanguage {
            let system = """
            You are an expert editor and native \(targetLabel) writer. \
            Revise the text to improve clarity, conciseness, and coherence \
            so it reads like polished native prose. \
            Preserve the original meaning and tone. Output only the revised text. \
            Begin directly with the revised text. Do not add any preamble, labels, or commentary.
            """
            var user = "Polish the following \(targetLabel) text:\n\n\(text)"
            if !docCtx.isEmpty { user += "\n\n[\(docCtx)]" }
            return (system, user)
        }

        // --- Word / short phrase lookup ---
        if isWordLookup(text) {
            if isChinese {
                let system = """
                你是一位翻译引擎。当文本是单个单词时，请给出：\
                单词原始形态（如有）、语种、对应音标或转写、\
                所有含义（含词性）、至少三条双语示例。\
                格式：
                [语种] / 音标
                [词性] 含义
                例句：
                1. 例句 (翻译)
                如果提供了文档上下文（方括号内），用它来消歧术语，但不要在输出中包含它。
                """
                var user = "翻译为\(targetLabel)：\n\n\(text)"
                if !docCtx.isEmpty { user += "\n\n[\(docCtx)]" }
                return (system, user)
            } else {
                let system = """
                You are a translation engine. When the input is a single word, provide: \
                original form (if applicable), source language, phonetic transcription, \
                all meanings with parts of speech, and at least 3 bilingual example sentences. \
                Format:
                [Language] / Phonetics
                [POS] Meaning
                Examples:
                1. Example (Translation)
                If document context is provided in brackets, use it to disambiguate terminology but do not include it in your output.
                """
                var user = "Translate to \(targetLabel):\n\n\(text)"
                if !docCtx.isEmpty { user += "\n\n[\(docCtx)]" }
                return (system, user)
            }
        }

        // --- Full text translation ---
        let system: String
        var user: String

        if isChinese {
            // Chinese-target: "reshape" philosophy for natural, native Chinese output
            system = """
            你是一位资深中文重塑专家。你的任务不是逐字翻译，而是"重塑"：\
            完全吸收原文的思想、逻辑、语气和意图，\
            然后彻底抛弃原文的语法结构，\
            以中文母语者的思维，用最自然、最地道的\(targetLabel)重新表达。\
            要求：
            - 不出现翻译腔，读者应感受不到翻译痕迹
            - 长句拆短，被动转主动，符合中文表达习惯
            - 保持原文的风格和语气
            - 专业术语准确，通用表达地道
            - 只输出重塑后的译文，不要任何解释
            如果提供了文档上下文（方括号内），用它来消歧术语，但不要在输出中包含它。\
            直接以译文开头，不要加任何前言、标签或评论。
            """
            user = "将以下\(sourceLabel)文本重塑为\(targetLabel)：\n\n\(text)"
        } else {
            system = """
            You are a professional translator. Your goal is to produce a translation \
            that reads as if originally written in \(targetLabel) by a native speaker. \
            Requirements:
            - Convey the meaning, tone, and intent accurately
            - Use natural \(targetLabel) sentence structures and idioms, not calques from the source
            - Break up overly long sentences when needed for readability
            - Keep technical terms accurate and domain-appropriate
            - Output only the translated text, no explanations
            If document context is provided in brackets, use it to disambiguate terminology but do not include it in your output. \
            Begin directly with the translated text. Do not add any preamble, labels, or commentary.
            """
            user = "Translate from \(sourceLabel) to \(targetLabel):\n\n\(text)"
        }

        if !docCtx.isEmpty {
            user += "\n\n[\(docCtx)]"
        }

        return (system, user)
    }

    // MARK: - Word Explanation

    func explainWord(_ word: String, inSentence sentence: String) {
        stopWordExplanation()
        explanationWord = word
        wordExplanation = ""
        isExplainingWord = true

        let prefs = Preferences.shared
        let pid = prefs.translationAIProviderId
        let model: String = {
            let m = prefs.translationAIModel
            return m.isEmpty ? (ProviderRegistry.shared.provider(for: pid)?.defaultModelId ?? "") : m
        }()

        let systemPrompt = buildWordExplanationSystemPrompt()
        let userPrompt = buildWordExplanationUserPrompt(word: word, sentence: sentence)

        let config = ProviderConfig(providerId: pid, model: model)
        let messages = [LLMMessage(role: .user, text: userPrompt)]

        wordExplanationTask = Task { @MainActor in
            do {
                let svc = try await router.provider(for: config)
                let stream = svc.sendMessage(
                    messages: messages,
                    model: model,
                    systemPrompt: systemPrompt,
                    maxTokens: 4096
                )

                for try await chunk in stream {
                    switch chunk {
                    case .delta(let delta):
                        wordExplanation += delta
                    case .thinking, .toolUse, .toolInputDelta, .finished:
                        break
                    case .error(let msg):
                        wordExplanation += "\n\n⚠️ \(msg)"
                    }
                }
            } catch {
                if !(error is CancellationError) {
                    wordExplanation += "\n\n⚠️ \(error.localizedDescription)"
                }
            }
            isExplainingWord = false
        }
    }

    func stopWordExplanation() {
        wordExplanationTask?.cancel()
        wordExplanationTask = nil
        isExplainingWord = false
    }

    private func buildWordExplanationSystemPrompt() -> String {
        let accent = Preferences.shared.pronunciationAccent
        let targetLabel = targetLang.displayName
        let ipaNote = accent == .british
            ? "Use British English pronunciation (BrE IPA)."
            : "Use American English pronunciation (AmE IPA)."

        return """
        You are an expert word analyst. \(ipaNote) \
        Provide a deep, insightful explanation of the given word using the exact format specified. \
        All translations and explanations should be in \(targetLabel). \
        Use markdown formatting. Be concise but illuminating. \
        If the word appears in the given sentence context, tailor collocations and examples to that context.
        """
    }

    private func buildWordExplanationUserPrompt(word: String, sentence: String) -> String {
        let targetLabel = targetLang.displayName

        var prompt = """
        Explain this word in depth:

        **Word:** \(word)
        """
        if !sentence.isEmpty {
            prompt += "\n**Sentence context:** \(sentence)"
        }

        prompt += """


        Use this exact format (translate all annotations and explanations into \(targetLabel)):

        ## {Word}  /{phonetics}/  {\(targetLabel) translation}

        ### Core Semantics
        - **Original Image**: one-sentence physical image of the word's origin
        - **Core Imagery**: formula (e.g., warmth + time + protection = incubation)
        - **Explanation**: insightful analysis of deep meaning and modern usage

        ### One-liner
        > "English sentence demonstrating nuanced usage. \(targetLabel) philosophical summary."

        ### Collocations
        Common collocations, especially those appearing in the given sentence context.

        ### Derivatives
        Related derived words with brief meanings.

        ### Memory
        Etymology-based deep memory technique.
        """
        return prompt
    }

    func stopTranslation() {
        debounceTask?.cancel()
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
