import SwiftUI
import OakMarkdownUI

struct TranslationPanelView: View {
    @Bindable var translationVM: TranslationViewModel
    var voiceVM: VoiceViewModel?

    @State private var playingSection: PlayingSection?
    @State private var sourceHeight: CGFloat = 90

    private enum PlayingSection {
        case source, target
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            languageBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sourceSection

                    Divider()
                        .padding(.horizontal, OakStyle.Spacing.sm)

                    targetSection
                }
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
        HStack(spacing: 6) {
            Spacer(minLength: 0)

            LanguagePillButton(
                title: translationVM.sourceLang.nativeName,
                languages: TranslationLanguage.allCases,
                selection: $translationVM.sourceLang
            )

            SwapLanguagesButton(disabled: translationVM.sourceLang == .auto) {
                translationVM.swapLanguages()
            }

            LanguagePillButton(
                title: translationVM.targetLang.nativeName,
                languages: TranslationLanguage.targetCases,
                selection: $translationVM.targetLang
            )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.bottom, OakStyle.Spacing.xs)
        .onChange(of: translationVM.sourceLang) { _, _ in
            translationVM.onLanguageChange()
        }
        .onChange(of: translationVM.targetLang) { _, _ in
            translationVM.onLanguageChange()
        }
    }

    // MARK: - Source Section

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            TranslationSourceTextView(
                text: $translationVM.sourceText,
                height: $sourceHeight,
                font: OakStyle.Font.nsFont(size: OakStyle.Font.body),
                placeholder: "Enter text",
                onWordSelected: { word, sentence, _ in
                    translationVM.explainWord(word, inSentence: sentence)
                }
            )
            .frame(height: max(90, sourceHeight))
            .padding(.horizontal, OakStyle.Spacing.xs)
            .padding(.top, OakStyle.Spacing.xs)
            .onChange(of: translationVM.sourceText) { _, _ in
                translationVM.debouncedTranslate()
            }

            if !translationVM.explanationWord.isEmpty {
                wordExplanationSection
                    .padding(.horizontal, OakStyle.Spacing.sm)
                    .padding(.bottom, OakStyle.Spacing.xs)
            }

            sourceToolbar
        }
    }

    private var sourceToolbar: some View {
        HStack(spacing: 4) {
            if voiceVM != nil && !translationVM.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                voiceButton(for: .source)
            }

            Spacer()

            if !translationVM.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                toolbarButton(systemImage: "doc.on.doc", tooltip: "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(translationVM.sourceText, forType: .string)
                }
            }
        }
        .padding(.horizontal, OakStyle.Spacing.xs)
        .padding(.vertical, OakStyle.Spacing.xxs)
    }

    // MARK: - Target Section

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if translationVM.isTranslating && translationVM.translatedText.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Translating…")
                        .font(OakStyle.Font.styled(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    stopButton
                }
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.vertical, OakStyle.Spacing.xs)
            }

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
            } else if !translationVM.translatedText.isEmpty {
                StreamingMarkdownView(
                    markdown: translationVM.translatedText,
                    theme: .oak(fontSize: OakStyle.Font.body),
                    isStreaming: translationVM.isTranslating
                )
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.vertical, OakStyle.Spacing.xs)

                targetToolbar
            }
        }
    }

    private var targetToolbar: some View {
        HStack(spacing: 4) {
            if voiceVM != nil && !translationVM.translatedText.isEmpty {
                voiceButton(for: .target)
            }

            if translationVM.isTranslating {
                stopButton
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

    private var stopButton: some View {
        Button {
            translationVM.stopTranslation()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Stop")
    }

    // MARK: - Word Explanation (inline, below source text)

    private var wordExplanationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if translationVM.isExplainingWord {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(translationVM.explanationWord)
                    .font(OakStyle.Font.styled(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    translationVM.stopWordExplanation()
                    translationVM.wordExplanation = ""
                    translationVM.explanationWord = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, OakStyle.Spacing.sm)
            .padding(.top, OakStyle.Spacing.xs)

            if translationVM.wordExplanation.isEmpty && translationVM.isExplainingWord {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .padding(.bottom, OakStyle.Spacing.xs)
            } else {
                StreamingMarkdownView(
                    markdown: translationVM.wordExplanation,
                    theme: .oak(fontSize: 13),
                    isStreaming: translationVM.isExplainingWord
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.vertical, OakStyle.Spacing.xs)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.05))
        )
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
        VStack(spacing: 8) {
            Image(systemName: "translate")
                .font(.system(size: 24))
                .foregroundStyle(.quaternary)
            Text("Translation appears here")
                .font(OakStyle.Font.styled(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

// MARK: - Language Pill

/// A content-sized pull-down button styled like Apple's Translate language picker:
/// language name + trailing chevron, with a subtle pill fill on hover.
private struct LanguagePillButton: View {
    let title: String
    let languages: [TranslationLanguage]
    @Binding var selection: TranslationLanguage

    @State private var isHovering = false

    var body: some View {
        Menu {
            ForEach(languages) { lang in
                Button {
                    selection = lang
                } label: {
                    if lang == selection {
                        Label(lang.nativeName, systemImage: "checkmark")
                    } else {
                        Text(lang.nativeName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(OakStyle.Font.styled(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, OakStyle.Spacing.sm)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                    .fill(isHovering ? OakStyle.Colors.hoverBackground : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: OakStyle.Radius.standard))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
    }
}

// MARK: - Swap Languages Button

/// Circular icon button between the two language pills.
private struct SwapLanguagesButton: View {
    let disabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(isHovering && !disabled ? OakStyle.Colors.hoverBackground : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { isHovering = $0 }
        .help("Swap languages")
    }
}
