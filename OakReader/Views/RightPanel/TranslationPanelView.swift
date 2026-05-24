import SwiftUI

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
            Divider().padding(.horizontal, OakStyle.Spacing.sm)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sourceSection
                    Divider().padding(.horizontal, OakStyle.Spacing.sm)
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

            if translationVM.isTranslating {
                OakToolButton(systemImage: "stop.circle", tooltip: "Stop") {
                    translationVM.stopTranslation()
                }
            }

            if !translationVM.translatedText.isEmpty {
                OakToolButton(systemImage: "doc.on.doc", tooltip: "Copy translation") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(translationVM.translatedText, forType: .string)
                }
            }

            OakToolButton(systemImage: "arrow.trianglehead.2.counterclockwise", tooltip: "Clear") {
                translationVM.clear()
            }
        }
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.sm)
    }

    // MARK: - Language Bar

    private var languageBar: some View {
        HStack(spacing: 4) {
            Picker("", selection: $translationVM.sourceLang) {
                ForEach(TranslationLanguage.allCases) { lang in
                    Text(lang.nativeName).tag(lang)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)

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

            Picker("", selection: $translationVM.targetLang) {
                ForEach(TranslationLanguage.targetCases) { lang in
                    Text(lang.nativeName).tag(lang)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
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
            TextField("Enter text", text: $translationVM.sourceText, axis: .vertical)
                .font(OakStyle.Font.styledBody)
                .textFieldStyle(.plain)
                .lineLimit(3...10)
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.vertical, OakStyle.Spacing.sm)
                .onChange(of: translationVM.sourceText) { _, _ in
                    translationVM.debouncedTranslate()
                }

            if voiceVM != nil && !translationVM.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    voiceButton(for: .source)
                    Spacer()
                }
                .padding(.horizontal, OakStyle.Spacing.sm)
                .padding(.bottom, OakStyle.Spacing.xs)
            }
        }
    }

    // MARK: - Target Section

    private var targetSection: some View {
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
                .background(Color.yellow.opacity(0.1))
            }

            if translationVM.translatedText.isEmpty && !translationVM.isTranslating {
                emptyState
            } else {
                Text(translationVM.translatedText)
                    .font(OakStyle.Font.styledBody)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                    .padding(.horizontal, OakStyle.Spacing.sm)
                    .padding(.vertical, OakStyle.Spacing.xs)

                if voiceVM != nil && !translationVM.translatedText.isEmpty {
                    HStack {
                        voiceButton(for: .target)
                        Spacer()
                    }
                    .padding(.horizontal, OakStyle.Spacing.sm)
                    .padding(.bottom, OakStyle.Spacing.xs)
                }
            }
        }
    }

    // MARK: - Voice Playback

    private func voiceButton(for section: PlayingSection) -> some View {
        let isPlaying = playingSection == section && (voiceVM?.isSpeaking ?? false)
        return Button {
            if isPlaying {
                stopPlayback()
            } else {
                playText(for: section)
            }
        } label: {
            Image(systemName: isPlaying ? "stop.fill" : "speaker.wave.2.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(isPlaying ? "Stop" : "Play")
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
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}
