# Note System Roadmap

**Status:** Backlog
**Created:** 2026-05-13

## Goal

Make OakReader's notes a reader-native research workspace rather than a generic Markdown editor. The core loop should be:

```text
Read → highlight/quote → note with source anchor → ask AI → search later → cite/export
```

Nota is a useful reference for editing comfort, but OakReader's differentiator should be anchored notes over PDFs, web snapshots, audio/video transcripts, citations, and AI context.

## Current State

OakReader currently has two note-like surfaces:

1. **Attached notes**
   - Metadata in `notes` table.
   - Markdown content in `CatalogDatabase.notesDirectory`.
   - Edited through `NoteEditorView` / `MarkdownTextView` in the right panel.

2. **Standalone Markdown library items**
   - Imported/created as `ItemType.markdown` attachments.
   - Edited through `MarkdownViewerView`.
   - Appears in the library under the Notes smart collection.

Both use the same underlying editor component, but they do not yet share a full note/link/search/index model.

## Guiding Principles

- Keep Markdown/plain text as the source of truth.
- Optimize for research workflows, not general document writing.
- Source anchors should be first-class: page, rect, timestamp, transcript segment, cite key.
- Build indexing before advanced UI: backlinks, block search, AI context, and outline all depend on it.
- Prefer native macOS editing (`NSTextView`) over WKWebView editors.
- Add Typst before LaTeX if/when adding compiled note formats.

---

## Phase 0 — Correctness & Safety Fixes

### Requirements

- [ ] Fix note lookup in `LLMContextProvider.buildDocumentContext`.
  - Current code calls `fetchNotes(forItemId: storageKey)`, but `fetchNotes` expects the item UUID.
  - Use `vm.itemId` or `vm.libraryItem?.id.uuidString`.
- [ ] Restrict `NotePreviewView` file access.
  - Current preview uses `loadFileURL(... allowingReadAccessTo: /)`.
  - Replace with a scoped preview directory or narrowly allowed roots.
- [ ] Debounce preview reloads in split mode.
  - Avoid full WKWebView reload on every keystroke.
  - Target 200–400ms idle debounce.
- [ ] Add basic unit tests around pure logic.
  - `MarkdownRenderer.preprocessReferences`
  - `MarkdownRenderer.resolveImagePaths`
  - title extraction
  - `NoteService` file CRUD
  - `ContentChunker`
  - `SkillLoader`

### Affected Areas

- `OakReader/Services/AI/LLMContextProvider.swift`
- `OakReader/Views/RightPanel/NotePreviewView.swift`
- `OakReader/ViewModels/NotesViewModel.swift`
- `OakReader/Services/MarkdownRenderer.swift`
- `Package.swift` or Xcode test target setup

---

## Phase 1 — Editing Comfort

Bring the existing Markdown editor closer to Nota-level daily usability before adding new note formats.

### Requirements

- [ ] Spell check toggle.
- [ ] Auto-pair brackets, quotes, backticks, and parentheses.
- [ ] Default note template.
  - Blank
  - Dated
  - Per-item research note template
- [ ] Better list behavior.
  - Enter continues list.
  - Empty list item exits list.
  - Tab / Shift-Tab indents and outdents list items.
  - Toggle task shortcut.
- [ ] Basic table editing.
  - Tab / Shift-Tab between cells.
  - Enter inserts newline or new row behavior.
- [ ] Paste URL over selected text to create Markdown link.
- [ ] Copy link to current note.
- [ ] Copy link to current page/source position.
- [ ] Improve image paste naming.
  - Use timestamp or source-aware filename.
  - Preserve original extension when safe.

### Affected Areas

- `OakReader/Views/RightPanel/MarkdownTextView.swift`
- `OakReader/Views/RightPanel/NoteEditorView.swift`
- `OakReader/Views/Viewer/MarkdownViewerView.swift`
- `OakReader/ViewModels/NotesViewModel.swift`
- `OakReader/Services/NoteService.swift`
- `OakReader/Utilities/Preferences.swift`
- `OakReader/Views/Settings/NoteSettingsView.swift`

---

## Phase 2 — Unified Note Model

Resolve the conceptual split between attached notes and standalone Markdown items.

### Decision Needed

Choose whether standalone Markdown items are:

1. **Library items with markdown attachments** plus optional attached notes, or
2. **Notes promoted to first-class library items**, backed by the same `notes` table.

Recommendation: keep both user-facing concepts but share a common internal note/editor/link/index layer.

### Requirements

- [ ] Define a `NoteDocument` abstraction used by both attached notes and standalone notes.
- [ ] Share editor state, image handling, preview, title extraction, and source-link handling.
- [ ] Support note format metadata for future extensibility.
  - `markdown` now
  - `typst` later
  - `latex` later
- [ ] Add a stable note URL scheme.
  - `oak-note://{noteId}`
  - `oak-note://{noteId}/block/{blockId}`
  - `oak-ref://...` remains source-reference navigation.
- [ ] Decide whether standalone markdown library items should create a row in `notes` or remain attachment-only.

### Affected Areas

- `OakReader/Models/NoteModel.swift`
- `OakReader/Models/DatabaseRecords.swift`
- `OakReader/Services/NoteService.swift`
- `OakReader/Services/ImportService+Markdown.swift`
- `OakReader/Views/RightPanel/NoteEditorView.swift`
- `OakReader/Views/Viewer/MarkdownViewerView.swift`
- `OakReader/Document/MarkdownDocument.swift`
- `OakReader/Services/CatalogMigrations.swift`

---

## Phase 3 — Note / Block Index

Build the foundation for fast search, backlinks, outline, AI context, and future block-level operations.

### Proposed Schema

```sql
CREATE TABLE note_blocks (
  id TEXT PRIMARY KEY,
  note_id TEXT NOT NULL,
  item_id TEXT,
  block_type TEXT NOT NULL,
  text TEXT NOT NULL,
  line_start INTEGER NOT NULL,
  line_end INTEGER NOT NULL,
  heading_path TEXT,
  source_ref TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE note_links (
  id TEXT PRIMARY KEY,
  source_note_id TEXT NOT NULL,
  source_block_id TEXT,
  target_kind TEXT NOT NULL, -- note, item, page, citekey, url, tag
  target_value TEXT NOT NULL,
  raw_text TEXT NOT NULL,
  created_at TEXT NOT NULL
);
```

### Requirements

- [ ] Parse Markdown into block records.
  - heading
  - paragraph
  - list item
  - task
  - quote
  - code block
  - image
  - table
- [ ] Extract outgoing links.
  - `[[note]]`
  - `[[Page 12]]`
  - `[[@citekey, p.12]]`
  - Markdown links
  - tags
- [ ] Incrementally update index on save.
- [ ] Add FTS over note block text.
- [ ] Add note outline powered by parsed headings.
- [ ] Add block search.
- [ ] Add backlinks.
- [ ] Add unlinked mentions later.

### Affected Areas

- New: `OakReader/Services/NoteIndexService.swift`
- New: `OakReader/Models/NoteBlock.swift`
- New: `OakReader/Models/NoteLink.swift`
- `OakReader/Services/CatalogMigrations.swift`
- `OakReader/ViewModels/NotesViewModel.swift`
- `OakReader/Services/SemanticIndexService.swift`
- `OakReader/Views/Sidebar/MarkdownOutlineSidebarView.swift`

---

## Phase 4 — Reader-Native Source Anchors

Make notes deeply connected to source material.

### Source Reference Types

```text
PDF:        item_id + attachment_id + page + rects + selected_text
Web:        item_id + attachment_id + selector/text offset + selected_text
Markdown:   item_id + block_id/heading
Audio/video:item_id + timestamp range + transcript segment
Citation:   cite_key + page/locator
```

### Requirements

- [ ] Replace plain `[[Page X]]` with a richer internal source-reference model while preserving readable Markdown.
- [ ] Store source anchors in the note/block index.
- [ ] Click source reference in edit or preview mode to jump to source.
- [ ] Add “Copy Source Link” from PDF/web/media selections.
- [ ] Add “Quote to Note” command.
- [ ] Add “Image/area capture to Note” command.
- [ ] Show all notes/quotes for current item.
- [ ] Show all notes mentioning current cite key.
- [ ] Export source-linked notes to Markdown with stable citation format.

### Affected Areas

- `OakReader/Views/Viewer/TextSelectionPopupPanel.swift`
- `OakReader/Views/Viewer/AreaSelectionPopupPanel.swift`
- `OakReader/Views/Viewer/WebSelectionPopupPanel.swift`
- `OakReader/ViewModels/NotesViewModel.swift`
- `OakReader/Services/NoteService.swift`
- `OakReader/Services/AnnotationStore.swift`
- `OakReader/Models/AnnotationPosition.swift`
- New: `OakReader/Models/SourceReference.swift`

---

## Phase 5 — Navigation & Discovery

Use the index to make notes easy to find and traverse.

### Requirements

- [ ] Quick Open notes.
- [ ] Search note blocks, not just note titles.
- [ ] Search results show block type icon and note context.
- [ ] Right sidebar note outline.
- [ ] Backlinks panel.
- [ ] Mention panel for current item/citation.
- [ ] “Open Random Note”.
- [ ] “Merge Note” command.
  - Append source note content to target note.
  - Rewrite links to source note.
  - Delete/archive source note.
- [ ] Pinned notes and recent notes.

### Affected Areas

- `OakReader/Views/Library/LibraryRootView.swift`
- `OakReader/Views/RightPanel/NoteListView.swift`
- `OakReader/Views/Sidebar/MarkdownOutlineSidebarView.swift`
- `OakReader/Services/LibraryStore.swift`
- New: `OakReader/Views/Notes/NoteSearchView.swift`
- New: `OakReader/Services/NoteMergeService.swift`

---

## Phase 6 — AI Context for Notes

Make notes first-class AI context.

### Requirements

- [ ] Fix AI note injection for attached notes.
- [ ] Add `@notes` mention support in chat.
- [ ] Add `@note:{title}` mention support.
- [ ] Add `@block:{heading}` or selected block context later.
- [ ] Add tools:
  - `search_notes`
  - `read_note`
  - `append_to_note`
  - `create_note`
- [ ] Let AI save structured output directly to a note.
- [ ] Let AI transform selected note text with inline diff accept/reject.
- [ ] Semantic index notes and note blocks.

### Affected Areas

- `OakReader/ViewModels/ChatViewModel.swift`
- `OakReader/Services/AI/LLMContextProvider.swift`
- `OakReader/Services/AI/SearchTools.swift`
- `OakReader/Services/SemanticIndexService.swift`
- `OakReader/Views/RightPanel/ChatInputTextView.swift`
- `OakReader/Views/RightPanel/MarkdownSelectionPopupPanel.swift`

---

## Phase 7 — Unified Commands, Mentions, and Skills

Unify editor commands, chat slash commands, and skill selection.

### Mental Model

```text
/     = action or skill
@     = entity/context
[[ ]] = durable link
```

Examples:

```text
/summarize
/extract-quotes
/create-note
@document
@selection
@notes
@collection:ML Papers
[[Page 12]]
[[@smith2024, p.8]]
```

### Requirements

- [ ] Share a reusable completion model between note editor and chat input.
- [ ] Add note editor `@` mentions.
- [ ] Add note editor `[[` completions.
- [ ] Unify built-in `Skill` and file-based `AgentSkill` presentation.
- [ ] Show file-based skills in `SkillPickerBar`.
- [ ] Add “Create Skill from selection/chat/note” later.

### Related Backlog

- `specs/backlog/extension-system.md`
- `docs/issues/2026-05-12-slash-and-mention-triggers.md`
- `docs/issues/2026-05-12-plugin-skill-ux-redesign.md`

---

## Phase 8 — Typst Notes

Add compiled academic note formats only after Markdown notes are solid.

### Recommendation

Implement Typst before LaTeX because Typst offers fast compilation and a better live-preview experience.

### Requirements

- [ ] Add `NoteFormat` enum.
  - `markdown`
  - `typst`
  - `latex` later
- [ ] Add Typst compilation service.
- [ ] Build Typst edit/preview/split view with PDFKit preview.
- [ ] Add format picker when creating note.
- [ ] Add Typst syntax highlighting.
- [ ] Generate bibliography file from library citations.
- [ ] Support `@citekey` completions.

### Related Backlog

- `docs/issues/2026-05-12-latex-typst-note-editor.md`

---

## Non-Goals for Now

- Full WYSIWYG block editor.
- Notion-style database properties inside notes.
- Full plugin marketplace.
- MCP server lifecycle.
- ExtensionKit app extensions.
- Cloud sync.
- LaTeX-first editing.

These may be valuable later, but they are not required to prove the reader-native note workflow.

## Suggested Near-Term Order

1. Phase 0 correctness fixes.
2. Phase 1 editing comfort.
3. Phase 3 note/block index.
4. Phase 4 source anchors.
5. Phase 6 AI note context.
6. Phase 7 unified commands/skills.
7. Phase 8 Typst notes.
