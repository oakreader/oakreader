import SwiftUI

struct TranslationPanelView: View {
    @Bindable var translationVM: TranslationViewModel

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            languageBar
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sourceSection
                    targetSection
                }
                .padding(12)
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Translation")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            if translationVM.isTranslating {
                Button {
                    translationVM.stopTranslation()
                } label: {
                    Image(systemName: "stop.circle")
                }
                .buttonStyle(.borderless)
                .help("Stop")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    // MARK: - Language Bar

    private var languageBar: some View {
        HStack(spacing: 0) {
            Picker("Source", selection: $translationVM.sourceLang) {
                ForEach(TranslationLanguage.allCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .onChange(of: translationVM.sourceLang) { _, _ in
                translationVM.onLanguageChange()
            }

            Button {
                translationVM.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .disabled(translationVM.sourceLang == .auto)
            .help("Swap languages")
            .padding(.horizontal, 4)

            Picker("Target", selection: $translationVM.targetLang) {
                ForEach(TranslationLanguage.targetCases) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .onChange(of: translationVM.targetLang) { _, _ in
                translationVM.onLanguageChange()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Source Section

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextEditor(text: $translationVM.sourceText)
                .font(.system(size: 13))
                .frame(minHeight: 80, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )

            Button {
                translationVM.translate()
            } label: {
                HStack(spacing: 4) {
                    if translationVM.isTranslating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Translate")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(translationVM.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || translationVM.isTranslating)
            .controlSize(.large)
        }
    }

    // MARK: - Target Section

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Result")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if !translationVM.translatedText.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(translationVM.translatedText, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy translation")
                }
            }

            if let error = translationVM.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.06))
                    )
            }

            Text(translationVM.translatedText.isEmpty ? " " : translationVM.translatedText)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
    }
}
