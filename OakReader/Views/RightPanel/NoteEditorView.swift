import SwiftUI
import AppKit

/// Editor modes for the note editor.
enum NoteEditorMode: String, CaseIterable {
    case edit
    case preview
    case split

    var icon: String {
        switch self {
        case .edit: return "square.and.pencil"
        case .preview: return "book"
        case .split: return "rectangle.split.2x1"
        }
    }

    var label: String {
        switch self {
        case .edit: return "Edit"
        case .preview: return "Preview"
        case .split: return "Split"
        }
    }
}

/// Note editor with Edit / Preview / Split mode toggle.
/// Replaces the old WYSIWYG WKWebView editor with a plain-text NSTextView
/// and a Textual-based markdown preview.
struct NoteEditorView: View {
    let notesVM: NotesViewModel

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

    @State private var editorCoordinator: MarkdownTextView.Coordinator?
    @State private var dictationService = DictationService()

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

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            ZStack(alignment: .top) {
                switch currentMode {
                case .edit:
                    editorPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .preview:
                    previewPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .split:
                    splitPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Dictation recording indicator
                if dictationService.isDictating {
                    DictationOverlayView(onStop: { dictationService.stop() })
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: dictationService.isDictating)
        }
        .onAppear(perform: setupDictationEventHandler)
        .onDisappear { dictationService.stop() }
        .background(DictationKeyMonitor(onToggle: { toggleDictation() }))
        .alert(
            "Dictation Not Available",
            isPresented: Binding(
                get: { dictationService.errorMessage != nil },
                set: { if !$0 { dictationService.errorMessage = nil } }
            )
        ) {
            Button("Open Voice Settings") {
                dictationService.errorMessage = nil
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            Button("Cancel", role: .cancel) {
                dictationService.errorMessage = nil
            }
        } message: {
            Text(dictationService.errorMessage ?? "")
        }
    }

    /// Toggle dictation on/off. Only works in edit or split mode.
    private func toggleDictation() {
        print("[Dictation] toggleDictation() called, mode=\(currentMode), isDictating=\(dictationService.isDictating)")
        guard currentMode == .edit || currentMode == .split else {
            print("[Dictation] ⚠ Blocked — not in edit/split mode")
            return
        }
        dictationService.toggle()
    }

    /// Wire dictation events to the text view's insertion methods.
    private func setupDictationEventHandler() {
        dictationService.onDictationEvent = { (event: DictationEvent) in
            guard let textView = editorCoordinator?.textView else { return }
            switch event {
            case .partial(let text):
                textView.insertDictationPartial(text)
            case .final(let text):
                textView.commitDictationFinal(text)
            case .error:
                textView.clearDictationPartial()
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            // Back button
            Button(action: { notesVM.deselectNote() }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                    Text("Notes")
                        .font(.system(size: 14, weight: .medium))
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .help("Back to notes list")

            Spacer()

            // Mode toggle — individual icon buttons
            ForEach(NoteEditorMode.allCases, id: \.rawValue) { mode in
                toolbarButton(
                    icon: mode.icon,
                    style: currentMode == mode ? .primary : .tertiary,
                    help: mode.label
                ) { currentModeRaw = mode.rawValue }
            }

            // Dictation toggle button
            if currentMode == .edit || currentMode == .split {
                toolbarButton(
                    icon: dictationService.isDictating ? "mic.fill" : "mic",
                    style: dictationService.isDictating ? .primary : .tertiary,
                    help: dictationService.isDictating ? "Stop dictation (⌥Space)" : "Start dictation (⌥Space)"
                ) { toggleDictation() }
            }

            // More menu (delete, pin)
            if let note = notesVM.selectedNote {
                Menu {
                    Button(action: { notesVM.togglePin(note) }) {
                        Label(
                            note.isPinned ? "Unpin" : "Pin to Top",
                            systemImage: note.isPinned ? "pin.slash" : "pin"
                        )
                    }
                    Divider()
                    Button(role: .destructive, action: { notesVM.deleteNote(note) }) {
                        Label("Delete Note", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: OakStyle.Font.icon, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                .contentShape(Rectangle())
                .help("More options")
            }
        }
        .padding(.horizontal, OakStyle.Spacing.sm)
        .padding(.vertical, OakStyle.Spacing.sm)
    }

    // MARK: - Editor Pane

    private var editorPane: some View {
        MarkdownTextView(
            text: Binding(
                get: { notesVM.editorContent },
                set: { notesVM.editorContentDidChange($0) }
            ),
            font: editorFont,
            lineHeight: CGFloat(lineHeight),
            lineSpacing: CGFloat(lineSpacing),
            letterSpacing: CGFloat(letterSpacing),
            accentColorHex: accentColorHex,
            onReferenceClick: handleReferenceClick,
            onImagePaste: { data in notesVM.saveImage(data) },
            onSelectionPopup: { screenPoint, text, range, textView in
                MarkdownSelectionPopupPanel.show(
                    at: screenPoint,
                    text: text,
                    range: range,
                    textView: textView,
                    viewModel: notesVM.parent
                )
            },
            onCoordinatorReady: { coordinator in
                editorCoordinator = coordinator
            },
            onDictationToggle: { toggleDictation() }
        )
    }

    // MARK: - Toolbar Button

    private func toolbarButton(
        icon: String, style: HierarchicalShapeStyle = .secondary,
        help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: OakStyle.Font.icon))
                .foregroundStyle(style)
                .frame(width: OakStyle.Size.buttonStandard, height: OakStyle.Size.buttonStandard)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Preview Pane

    private var previewPane: some View {
        NotePreviewView(
            content: notesVM.editorContent,
            baseURL: notesVM.notesDirectoryURL,
            onReferenceClick: handleReferenceClick
        )
    }

    // MARK: - Split Pane

    private var splitPane: some View {
        VSplitView {
            editorPane
                .frame(minHeight: 120)
            previewPane
                .frame(minHeight: 120)
        }
    }

    // MARK: - Reference Click

    private func handleReferenceClick(_ reference: String) {
        if reference.hasPrefix("@") {
            // Cite key reference: "@smith2024, p.12"
            let body = reference.dropFirst()
            let parts = body.split(separator: ",", maxSplits: 1)
            var pageIndex: Int?
            if parts.count > 1 {
                let pageStr = String(parts[1])
                let pattern = #"pp?\.\s*(\d+)"#
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: pageStr, range: NSRange(pageStr.startIndex..., in: pageStr)),
                   let range = Range(match.range(at: 1), in: pageStr),
                   let page = Int(pageStr[range]) {
                    pageIndex = page - 1
                }
            }
            if let pageIndex {
                notesVM.parent?.viewer.goToPage(pageIndex)
            }
        } else if let pageIndex = NotesViewModel.pageIndex(from: "[[\(reference)]]") {
            notesVM.parent?.viewer.goToPage(pageIndex)
        }
    }

}

// MARK: - Option+Space Key Monitor

/// Invisible NSViewRepresentable that installs an NSEvent local monitor for Option+Space.
private struct DictationKeyMonitor: NSViewRepresentable {
    let onToggle: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.onToggle = onToggle
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            if event.isDictationToggleShortcut {
                if event.window?.firstResponder is MarkdownNSTextView {
                    return event
                }
                coordinator?.onToggle?()
                return nil  // consume the event
            }
            return event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onToggle = onToggle
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var monitor: Any?
        var onToggle: (() -> Void)?

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit { removeMonitor() }
    }
}
