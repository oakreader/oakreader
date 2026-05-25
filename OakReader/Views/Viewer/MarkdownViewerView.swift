import SwiftUI
import AppKit
import Combine

/// Full-width markdown viewer/editor for standalone markdown library items.
/// Supports Edit / Preview / Split modes with debounced auto-save.
struct MarkdownViewerView: View {
    let viewModel: DocumentViewModel

    @AppStorage("noteEditorMode") private var currentModeRaw: String = "edit"
    @AppStorage("noteEditorFontFamily") private var fontFamily = ".AppleSystemUIFont"
    @AppStorage("noteEditorFontSize") private var fontSize: Double = 16
    @AppStorage("noteEditorLineHeight") private var lineHeight: Double = 1.3
    @AppStorage("noteEditorLineSpacing") private var lineSpacing: Double = 3.0
    @AppStorage("noteEditorLetterSpacing") private var letterSpacing: Double = 0.5
    @AppStorage("noteEditorAccentColor") private var accentColorHex: String = "#0CA69A"
    @AppStorage("noteEditorFontOverridden") private var fontOverridden: Bool = false
    @AppStorage("globalFontFamily") private var globalFontFamily: String = "system"
    @AppStorage("globalFontSize") private var globalFontSize: Double = 14.0

    @State private var saveTask: Task<Void, Never>?

    private var currentMode: NoteEditorMode {
        NoteEditorMode(rawValue: currentModeRaw) ?? .edit
    }

    private var effectiveFontFamily: String {
        if fontOverridden { return fontFamily }
        return FontFamily(rawValue: globalFontFamily)?.fontName ?? ".AppleSystemUIFont"
    }

    private var effectiveFontSize: CGFloat {
        if fontOverridden { return CGFloat(fontSize) }
        return CGFloat(globalFontSize)
    }

    private var editorFont: NSFont {
        NSFont(name: effectiveFontFamily, size: effectiveFontSize)
            ?? NSFont.systemFont(ofSize: effectiveFontSize)
    }

    private var isZenMode: Bool { viewModel.state.isZenMode }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                if !isZenMode {
                    toolbar
                }

                if isZenMode {
                    zenPreviewPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch currentMode {
                    case .edit:
                        editorPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .preview:
                        previewPane
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }

            // Floating zen mode exit button
            if isZenMode {
                Button {
                    viewModel.appState?.dispatchAction(.toggleZenMode)
                } label: {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Exit Zen Mode")
                .padding(12)
            }
        }
        .onAppear {
            viewModel.markdownContent = viewModel.markdownDocument?.content ?? ""
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            Spacer()

            // Zen mode toggle
            Button {
                viewModel.appState?.dispatchAction(.toggleZenMode)
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: OakStyle.Font.icon))
                    .foregroundStyle(.tertiary)
                    .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zen Mode (⇧⌘.)")

            // Mode toggle — segmented picker
            Picker("Mode", selection: $currentModeRaw) {
                ForEach(NoteEditorMode.allCases, id: \.rawValue) { mode in
                    Image(systemName: mode.icon)
                        .tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 60)
            .help("Switch editor mode")
        }
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.xs)
    }

    // MARK: - Editor Pane

    private var editorPane: some View {
        MarkdownTextView(
            text: Binding(
                get: { viewModel.markdownContent },
                set: { newValue in
                    viewModel.markdownContent = newValue
                    scheduleSave(newValue)
                }
            ),
            font: editorFont,
            lineHeight: CGFloat(lineHeight),
            lineSpacing: CGFloat(lineSpacing),
            letterSpacing: CGFloat(letterSpacing),
            accentColorHex: accentColorHex,
            onImagePaste: { data in saveImage(data) },
            onSelectionPopup: { screenPoint, text, range, textView in
                MarkdownSelectionPopupPanel.show(
                    at: screenPoint,
                    text: text,
                    range: range,
                    textView: textView,
                    viewModel: viewModel
                )
            }
        )
    }

    // MARK: - Preview Pane

    private var previewPane: some View {
        NotePreviewView(
            content: viewModel.markdownContent,
            baseURL: viewModel.markdownDocument?.fileURL.deletingLastPathComponent()
        )
    }

    // MARK: - Zen Preview Pane

    private var zenPreviewPane: some View {
        NotePreviewView(
            content: viewModel.markdownContent,
            baseURL: viewModel.markdownDocument?.fileURL.deletingLastPathComponent()
        )
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Auto-Save

    private func scheduleSave(_ newContent: String) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms debounce
            guard !Task.isCancelled else { return }

            viewModel.markdownDocument?.content = newContent
            viewModel.markdownDocument?.save()

            // Sync title from first # heading
            syncTitle(from: newContent)
        }
    }

    private func syncTitle(from text: String) {
        guard let store = viewModel.libraryStore,
              let item = viewModel.libraryItem else { return }

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let heading = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !heading.isEmpty && heading != item.title {
                    store.updateTitle(item, title: heading)
                }
                return
            }
        }
    }

    // MARK: - Image Paste

    private func saveImage(_ data: Data) -> String? {
        guard let dir = viewModel.markdownDocument?.fileURL.deletingLastPathComponent() else { return nil }
        let imagesDir = dir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        let fileName = UUID().uuidString + ".png"
        let fileURL = imagesDir.appendingPathComponent(fileName)
        do {
            try data.write(to: fileURL)
            return "images/\(fileName)"
        } catch {
            return nil
        }
    }
}
