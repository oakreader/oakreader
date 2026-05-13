# LaTeX / Typst Note Editor

## Summary

Add LaTeX and Typst as alternative note formats alongside Markdown. Users can choose their preferred format when creating a note, with live PDF preview via compilation.

## Motivation

OakReader targets academic users who read and annotate research papers. These users often think in LaTeX. The current note system only supports Markdown (with KaTeX for inline math), which is limiting for heavy math writing and doesn't integrate with LaTeX-based publication workflows.

Codex.app's plugin architecture (embeddable server, lifecycle hooks, capability declarations) also highlights gaps in OakReader's plugin design that this feature can address.

## Design

### Rendering Pipelines

```
Markdown:  .md  → cmark-gfm → HTML → WKWebView  (existing)
Typst:     .typ → typst      → PDF  → PDFKit     (new, <100ms compile)
LaTeX:     .tex → tectonic    → PDF  → PDFKit     (new, 1-3s compile)
```

Typst is the recommended default for new math-heavy notes due to sub-100ms compilation enabling real-time preview. LaTeX is the power-user option for users with existing `.tex` workflows.

### Storage

```
{storage-key}/notes/
  {note-id}.md        # existing — Markdown
  {note-id}.typ       # new — Typst source
  {note-id}.tex       # new — LaTeX source
  .build/             # cached compiled PDF output
```

### Note Creation Flow

"New Note" offers a format picker: **Markdown** / **Typst** / **LaTeX**. The viewer dispatches to the appropriate editor + preview combination using the same edit/preview/split layout.

### Citation Integration

- LaTeX notes: `\cite{citekey}` with auto-generated `.bib` from library `citationJSON`
- Typst notes: `@citekey` with auto-generated `.yml` bibliography
- Leverage existing `CiteKeyService` and `CitationFormatter`

## Requirements

### Phase 1 — Typst Notes (fast-compile path)

- [ ] Add `NoteFormat` enum (`.markdown`, `.typst`, `.latex`) to `MarkdownDocument` or new `NoteDocument`
- [ ] Add `typst` compilation service: source → PDF, with error capture
- [ ] Build `TypstViewerView` with edit/preview/split using `PDFKit` as preview pane
- [ ] Format picker in note creation UI
- [ ] Typst syntax highlighting in the text editor
- [ ] Auto-generate `.bib.yml` from library citations for `@citekey` references

### Phase 2 — LaTeX Notes (slow-compile path)

- [ ] Add `tectonic` to bundled plugin definitions in `PluginService`
- [ ] LaTeX compilation service with longer debounce (~2s) and "Compiling..." indicator
- [ ] LaTeX error display in preview pane (parse `tectonic` stderr)
- [ ] Auto-generate `.bib` file from library citations for `\cite{}` references
- [ ] LaTeX syntax highlighting in the text editor

### Phase 3 — Plugin Architecture Improvements (inspired by Codex)

- [ ] Add lifecycle hooks to `PluginManifest` (`check`, `install`, `activate`, `uninstall`)
- [ ] Add capability declarations (`documentImport`, `documentExport`, `documentRender`, `contentTransform`)
- [ ] Support long-running plugin processes via MCP/stdio transport
- [ ] `oak serve` command for headless embedding (IDE/browser extensions)

## Affected Areas

- `Models/PluginManifest.swift` — lifecycle hooks, capabilities
- `Services/PluginService.swift` — new `latex` plugin definition, capability dispatch
- `CLI/PluginRegistry.swift` — mirror new plugin fields
- `Document/MarkdownDocument.swift` — extend or split into `NoteDocument` with format awareness
- `Views/Viewer/MarkdownViewerView.swift` — dispatch by format
- `Views/Viewer/TypstViewerView.swift` — new (edit + PDFKit preview)
- `Views/Viewer/LaTeXViewerView.swift` — new (edit + PDFKit preview + error display)
- `Services/TypstCompilationService.swift` — new
- `Services/LaTeXCompilationService.swift` — new
- `Services/CitationFormatter.swift` — BibTeX/BibYAML export for note compilation
- `Models/ItemType.swift` — possibly no change if notes remain attached to items
- `Preferences.swift` — default note format preference
