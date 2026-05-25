import SwiftUI
import Textual

struct TranslationPanelView: View {
    @Bindable var translationVM: TranslationViewModel
    var voiceVM: VoiceViewModel?

    @State private var playingSection: PlayingSection?

    private enum PlayingSection {
        case source, target
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            languageBar

            ScrollView {
                VStack(spacing: OakStyle.Spacing.sm) {
                    sourceCard
                    translateButton
                    targetCard

                    if !translationVM.wordExplanation.isEmpty || translationVM.isExplainingWord {
                        wordExplanationCard
                    }
                }
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.vertical, OakStyle.Spacing.xs)
            }
            .scrollContentBackground(.hidden)
        }
        .onChange(of: voiceVM?.isSpeaking) { _, speaking in
            if speaking == false { playingSection = nil }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("Translation")
                .font(OakStyle.ChatFont.headerTitle)

            Spacer()
        }
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.sm)
    }

    // MARK: - Language Bar

    private var languageBar: some View {
        HStack(spacing: 4) {
            languageMenuButton(
                title: translationVM.sourceLang.nativeName,
                languages: TranslationLanguage.allCases,
                selection: $translationVM.sourceLang
            )

            Button {
                translationVM.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(translationVM.sourceLang == .auto)
            .help("Swap languages")

            languageMenuButton(
                title: translationVM.targetLang.nativeName,
                languages: TranslationLanguage.targetCases,
                selection: $translationVM.targetLang
            )
        }
        .frame(height: 36)
        .padding(.horizontal, OakStyle.Spacing.xs)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.bottom, OakStyle.Spacing.sm)
        .onChange(of: translationVM.sourceLang) { _, _ in
            translationVM.onLanguageChange()
        }
        .onChange(of: translationVM.targetLang) { _, _ in
            translationVM.onLanguageChange()
        }
    }

    // MARK: - Source Card

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TranslationSourceTextView(
                text: $translationVM.sourceText,
                font: OakStyle.Font.nsFont(size: OakStyle.Font.body),
                placeholder: "Enter text",
                onWordSelected: { word, sentence, _ in
                    translationVM.explainWord(word, inSentence: sentence)
                }
            )
            .frame(minHeight: 60, maxHeight: 150)
            .onChange(of: translationVM.sourceText) { _, _ in
                translationVM.debouncedTranslate()
            }

            // Toolbar
            sourceToolbar
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var sourceToolbar: some View {
        HStack(spacing: 4) {
            if voiceVM != nil && !translationVM.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                voiceButton(for: .source)
            }

            Spacer()

            if !translationVM.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Copy source
                toolbarButton(systemImage: "doc.on.doc", tooltip: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(translationVM.sourceText, forType: .string)
                }
            }
        }
        .padding(.horizontal, OakStyle.Spacing.xs)
        .padding(.vertical, OakStyle.Spacing.xxs)
    }

    // MARK: - Translate Button

    private var translateButton: some View {
        HStack {
            Spacer()
            Button {
                if translationVM.isTranslating {
                    translationVM.stopTranslation()
                } else {
                    translationVM.translate()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: translationVM.isTranslating ? "stop.fill" : "arrow.right.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(translationVM.isTranslating ? "Stop" : "Translate")
                        .font(OakStyle.Font.styled(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(.white)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(translationVM.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(translationVM.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1.0)
        }
    }

    // MARK: - Target Card

    private var displayText: String {
        if translationVM.isTranslating {
            return translationVM.translatedText.sealIncompleteMarkdown()
        }
        return translationVM.translatedText
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let error = translationVM.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.vertical, OakStyle.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if translationVM.translatedText.isEmpty && !translationVM.isTranslating {
                emptyState
            } else {
                StructuredText(markdown: displayText)
                    .textual.textSelection(.enabled)
                    .font(OakStyle.Font.styledBody)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                    .padding(.horizontal, OakStyle.Spacing.sm)
                    .padding(.vertical, OakStyle.Spacing.xs)

                // Toolbar
                targetToolbar
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var targetToolbar: some View {
        HStack(spacing: 4) {
            if voiceVM != nil && !translationVM.translatedText.isEmpty {
                voiceButton(for: .target)
            }

            Spacer()

            if !translationVM.translatedText.isEmpty {
                toolbarButton(systemImage: "doc.on.doc", tooltip: "Copy translation") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(translationVM.translatedText, forType: .string)
                }
            }
        }
        .padding(.horizontal, OakStyle.Spacing.xs)
        .padding(.vertical, OakStyle.Spacing.xxs)
    }

    // MARK: - Word Explanation Card

    private var explanationDisplayText: String {
        if translationVM.isExplainingWord {
            return translationVM.wordExplanation.sealIncompleteMarkdown()
        }
        return translationVM.wordExplanation
    }

    private var wordExplanationCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if translationVM.isExplainingWord {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(translationVM.explanationWord)
                    .font(OakStyle.Font.styled(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                toolbarButton(systemImage: "xmark", tooltip: "Dismiss") {
                    translationVM.stopWordExplanation()
                    translationVM.wordExplanation = ""
                    translationVM.explanationWord = ""
                }
            }
            .padding(.horizontal, OakStyle.Spacing.sm)
            .padding(.top, OakStyle.Spacing.xs)

            StructuredText(markdown: explanationDisplayText)
                .textual.textSelection(.enabled)
                .font(OakStyle.Font.styled(size: 13))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.vertical, OakStyle.Spacing.xs)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    // MARK: - Language Menu Button

    private func languageMenuButton(
        title: String,
        languages: [TranslationLanguage],
        selection: Binding<TranslationLanguage>
    ) -> some View {
        Menu {
            ForEach(languages) { lang in
                Button {
                    selection.wrappedValue = lang
                } label: {
                    if lang == selection.wrappedValue {
                        Label(lang.nativeName, systemImage: "checkmark")
                    } else {
                        Text(lang.nativeName)
                    }
                }
            }
        } label: {
            Text(title)
                .font(OakStyle.Font.styled(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Rectangle())
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Shared Components

    private func toolbarButton(systemImage: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }

    // MARK: - Voice Playback

    private func voiceButton(for section: PlayingSection) -> some View {
        let isPlaying = playingSection == section && (voiceVM?.isSpeaking ?? false)
        return toolbarButton(
            systemImage: isPlaying ? "stop.fill" : "speaker.wave.2.fill",
            tooltip: isPlaying ? "Stop" : "Play"
        ) {
            if isPlaying {
                stopPlayback()
            } else {
                playText(for: section)
            }
        }
    }

    private func playText(for section: PlayingSection) {
        guard let voiceVM else { return }
        let text: String
        switch section {
        case .source:
            text = translationVM.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        case .target:
            text = translationVM.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return }
        playingSection = section
        voiceVM.speakText(text)
    }

    private func stopPlayback() {
        voiceVM?.stopSpeaking()
        playingSection = nil
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "translate")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Enter text to translate")
                .font(OakStyle.Font.styled(size: 14))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }
}
