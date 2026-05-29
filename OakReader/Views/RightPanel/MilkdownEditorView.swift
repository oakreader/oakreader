import SwiftUI
import OakAI
import OakEditor

/// Adapts the reusable `OakEditor.MilkdownEditor` to OakReader's notes feature:
/// content + autosave come from `NotesViewModel`, AI config from `Preferences`,
/// image storage from `NoteService`, and `[[reference]]` clicks drive PDF nav.
struct MilkdownEditorView: View {
    let notesVM: NotesViewModel
    /// Identity of the note shown; changing it reloads content into the editor.
    let noteId: UUID
    var onReferenceClick: ((String) -> Void)?

    /// Body-font choice from Settings ▸ Notes; observed so changes apply live.
    @AppStorage("noteEditorFontFamily") private var noteFontFamily: String = "default"

    private var aiConfig: EditorAIConfig {
        let prefs = Preferences.shared
        let providerId = prefs.aiProviderId
        let model = prefs.aiModel.isEmpty
            ? (ProviderRegistry.shared.provider(for: providerId)?.defaultModelId ?? "")
            : prefs.aiModel
        return EditorAIConfig(providerId: providerId, model: model, systemPrompt: Self.systemPrompt)
    }

    var body: some View {
        MilkdownEditor(
            content: notesVM.editorContent,
            identity: noteId,
            theme: .auto,
            fontFamily: Self.cssFontStack(noteFontFamily),
            aiConfig: aiConfig,
            resourceBaseURL: notesVM.notesDirectoryURL,
            onChange: { notesVM.editorContentDidChange($0) },
            imageUploader: { data, ext in notesVM.saveImage(data, fileExtension: ext) },
            onReferenceClick: onReferenceClick,
            onTagClick: nil,
            onSelection: { selection in
                NoteSelectionPopupPanel.show(
                    atTop: selection.topScreenPoint,
                    atBottom: selection.bottomScreenPoint,
                    text: selection.text,
                    runAI: selection.runAI,
                    viewModel: notesVM.parent,
                    onDismiss: {}
                )
            },
            onSelectionCleared: { NoteSelectionPopupPanel.dismissCurrent() }
        )
    }

    /// Map a Settings ▸ Notes font choice to a CSS font-family stack for the
    /// editor. `nil` keeps the theme's default serif. Picker values are either
    /// sentinels ("default"/"system"/"mono") or a literal installed font name.
    static func cssFontStack(_ family: String) -> String? {
        switch family {
        case "", "default":
            return nil
        case "system", ".AppleSystemUIFont":
            return "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', 'PingFang SC', sans-serif"
        case "mono":
            return "'PT Mono', ui-monospace, 'SF Mono', Menlo, monospace"
        default:
            // A specific installed family; keep serif fallbacks for missing glyphs.
            return "'\(family)', 'PT Serif', Georgia, serif"
        }
    }

    private static let systemPrompt = """
    You are a writing assistant embedded in a markdown editor.

    Rules:
    - Output markdown only. Never wrap your output in code fences.
    - Never include preambles, explanations, or sign-offs — output only the edited or generated content itself.
    - Preserve the original markdown structure (headings, lists, links, code blocks) unless the instruction explicitly asks to change it.
    - If a <selection> is provided, return only the replacement for that selection — do not repeat surrounding document context.
    - If no <selection> is provided, return content to insert at the cursor that flows with the surrounding document.
    """
}
