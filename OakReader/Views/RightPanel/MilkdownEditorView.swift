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
