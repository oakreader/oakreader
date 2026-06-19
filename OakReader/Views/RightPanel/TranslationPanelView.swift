import SwiftUI
import OakMarkdownUI

/// Mobile-translate-style panel: a full-width language selector on top, then two
/// stacked cards — a source (input) card and an emphasized result (output) card —
/// each self-contained with its own language label and action row. Modeled on the
/// Apple Translate / Google Translate / DeepL vertical layout, which reads well in
/// OakReader's narrow right-panel column.
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

            ScrollView {
                VStack(spacing: OakStyle.Spacing.sm) {
                    languageSelector
                    sourceCard
                    resultCard
                    lookupsSection
                }
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.bottom, OakStyle.Spacing.md)
            }
            .scrollContentBackground(.hidden)
        }
        .task { translationVM.loadLookups() }
        .onChange(of: voiceVM?.isSpeaking) { _, speaking in
            if speaking == false { playingSection = nil }
        }
    }

    // MARK: - Lookup history (this document)

    @ViewBuilder
    private var lookupsSection: some View {
        if !translationVM.lookups.isEmpty {
            VStack(alignment: .leading, spacing: OakStyle.Spacing.xs) {
                HStack {
                    Text("LOOKUPS (\(translationVM.lookups.count))")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Clear") { translationVM.clearLookups() }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
                ForEach(translationVM.lookups) { lookup in
                    LookupCardRow(lookup: lookup, onDelete: { translationVM.deleteLookup(lookup) })
                }
            }
            .padding(.top, OakStyle.Spacing.xs)
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

    // MARK: - Language Selector

    /// Full-width selector bar: source pill · swap · target pill, each pill
    /// expanding to fill half the bar (balanced like Google Translate).
    private var languageSelector: some View {
        HStack(spacing: 4) {
            LanguagePillButton(
                title: translationVM.sourceLang.nativeName,
                languages: TranslationLanguage.allCases,
                selection: $translationVM.sourceLang
            )
            .frame(maxWidth: .infinity)

            SwapLanguagesButton(disabled: translationVM.sourceLang == .auto) {
                translationVM.swapLanguages()
            }

            LanguagePillButton(
                title: translationVM.targetLang.nativeName,
                languages: TranslationLanguage.targetCases,
                selection: $translationVM.targetLang
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, OakStyle.Spacing.xs)
        .padding(.vertical, OakStyle.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: OakStyle.Radius.concave)
                .fill(Color.primary.opacity(0.04))
        )
        .onChange(of: translationVM.sourceLang) { _, _ in
            translationVM.onLanguageChange()
        }
        .onChange(of: translationVM.targetLang) { _, _ in
            translationVM.onLanguageChange()
        }
    }

    // MARK: - Source Card

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: OakStyle.Spacing.xs) {
            cardLabel(translationVM.sourceLang.nativeName)

            TranslationSourceTextView(
                text: $translationVM.sourceText,
                height: $sourceHeight,
                font: OakStyle.Font.nsFont(size: OakStyle.Font.body),
                placeholder: "Enter text",
                onWordSelected: { selection, sentence, _ in
                    translationVM.explainSelection(selection, inSentence: sentence)
                }
            )
            .frame(height: max(72, sourceHeight))
            .onChange(of: translationVM.sourceText) { _, _ in
                translationVM.debouncedTranslate()
            }

            if !translationVM.explanationWord.isEmpty {
                wordExplanationSection
            }

            cardActionRow(
                section: .source,
                text: translationVM.sourceText,
                copyTooltip: "Copy",
                showStop: false
            )
        }
        .padding(OakStyle.Spacing.sm)
        .cardSurface(filled: false)
    }

    // MARK: - Result Card

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: OakStyle.Spacing.xs) {
            cardLabel(translationVM.targetLang.nativeName)

            resultBody

            if !translationVM.translatedText.isEmpty || translationVM.isTranslating {
                cardActionRow(
                    section: .target,
                    text: translationVM.translatedText,
                    copyTooltip: "Copy translation",
                    showStop: translationVM.isTranslating
                )
            }
        }
        .padding(OakStyle.Spacing.sm)
        .cardSurface(filled: true)
    }

    @ViewBuilder
    private var resultBody: some View {
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
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if translationVM.translatedText.isEmpty && translationVM.isTranslating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Translating…")
                    .font(OakStyle.Font.styled(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        } else if translationVM.translatedText.isEmpty {
            // Quiet placeholder — the result is the hero, so keep it understated.
            Text("Translation appears here")
                .font(OakStyle.Font.styled(size: 14))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        } else {
            // Result is the hero: render one step larger than the source text.
            StreamingMarkdownView(
                markdown: translationVM.translatedText,
                theme: .oak(fontSize: OakStyle.Font.body + 1),
                isStreaming: translationVM.isTranslating
            )
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Card Building Blocks

    /// Small uppercase language caption at the top of each card.
    private func cardLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
    }

    /// Bottom action row: speaker (left) + stop/copy (right).
    private func cardActionRow(
        section: PlayingSection,
        text: String,
        copyTooltip: String,
        showStop: Bool
    ) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(spacing: 2) {
            if voiceVM != nil && !trimmed.isEmpty {
                voiceButton(for: section)
            }

            Spacer()

            if showStop {
                stopButton
            }

            if !trimmed.isEmpty {
                toolbarButton(systemImage: "doc.on.doc", tooltip: copyTooltip) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
        .frame(minHeight: 24)
    }

    private var stopButton: some View {
        Button {
            translationVM.stopTranslation()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Stop")
    }

    // MARK: - Word Explanation (inline, inside source card)

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
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
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
}

// MARK: - Card Surface

private extension View {
    /// Rounded card surface. Both source and result sit on the same solid white
    /// surface as the AI chat input (`diaSurface` — ≈#FEFFFF light / #2D2D2D dark),
    /// with a clear hairline border so the cards read as crisp panels rather than
    /// grey washes picked up from the window background.
    func cardSurface(filled: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: 14)
                .fill(OakStyle.Colors.diaSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
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
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, OakStyle.Spacing.sm)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: OakStyle.Radius.standard)
                    .fill(isHovering ? OakStyle.Colors.hoverBackground : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: OakStyle.Radius.standard))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
                .frame(width: 28, height: 28)
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
