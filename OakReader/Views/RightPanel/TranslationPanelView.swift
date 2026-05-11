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
        HStack(spacing: 8) {
            languageMenu(
                selection: $translationVM.sourceLang,
                languages: TranslationLanguage.allCases.map { $0 }
            )

            Button {
                translationVM.swapLanguages()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .disabled(translationVM.sourceLang == .auto)
            .help("Swap languages")

            languageMenu(
                selection: $translationVM.targetLang,
                languages: TranslationLanguage.targetCases
            )
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func languageMenu(
        selection: Binding<TranslationLanguage>,
        languages: [TranslationLanguage]
    ) -> some View {
        Menu {
            ForEach(languages) { lang in
                Button {
                    selection.wrappedValue = lang
                    translationVM.onLanguageChange()
                } label: {
                    if selection.wrappedValue == lang {
                        Label(lang.nativeName, systemImage: "checkmark")
                    } else {
                        Text(lang.nativeName)
                    }
                }
            }
        } label: {
            HStack {
                Text(selection.wrappedValue.nativeName)
                    .font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
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
                .onChange(of: translationVM.sourceText) { _, _ in
                    translationVM.debouncedTranslate()
                }
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
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
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
