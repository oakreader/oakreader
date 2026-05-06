# Unified Annotation Store - PDF, Web Snapshot, EPUB

## Summary

Replace the PDF-only `annotations.jsonl` idea with a unified, database-backed annotation model. Annotations become OakReader data, not mutations inside PDF/HTML/EPUB files. PDFKit annotations, WebView highlights, and future EPUB CFI highlights are runtime projections of the same canonical rows.

This follows the important parts of Zotero's design: annotations are child records of file attachments, persisted in SQLite, exposed to the reader as JSON, and rendered by format-specific readers. JSON is still central, but it lives inside the database as `position_json` and in the reader/import/export boundary, not as a standalone `annotations.jsonl` source of truth.

Reference checked against Zotero source at commit `fda72a3`:

- `/private/tmp/zotero/resource/schema/userdata.sql`
- `/private/tmp/zotero/chrome/content/zotero/xpcom/annotations.js`
- `/private/tmp/zotero/chrome/content/zotero/xpcom/data/item.js`
- `/private/tmp/zotero/chrome/content/zotero/xpcom/data/items.js`
- `/private/tmp/zotero/chrome/content/zotero/xpcom/reader.js`
- `/private/tmp/zotero/test/content/support.js`

## Decision

Use SQLite as the canonical annotation store, with JSON payloads for format-specific annotation positions.

Do not store canonical annotations in `annotations.jsonl` alongside a PDF. JSONL can still be an import/export, debug, or backup format, but it should not be the primary application state.

Attach annotations to `attachments`, not only to top-level library `items`. A library item can have multiple attachments, and annotation coordinates/CFIs/selectors belong to one concrete file. Keep `item_id` on the annotation row as a denormalized query key for fast library-wide filtering.

Do not rewrite PDFs on normal annotation edits. Only generate a PDF with embedded annotations when the user explicitly exports or saves a copy with annotations.

## Why This Design

### User-facing performance

| Operation | Expected effect |
|---|---|
| PDF scrolling/rendering | Mostly unchanged; PDFKit still renders visible annotations |
| PDF open | Slightly slower; load DB annotations and project into PDFKit |
| Highlight/create/edit/delete | Faster or equal; write one DB row instead of rewriting a PDF |
| Annotation sidebar | Faster; query rows instead of scanning all pages |
| Search/filter/tags | Much faster and more flexible; indexed DB data |
| Sync | Much better; sync small rows instead of whole binary files |
| Export annotated PDF | Same or slower; projection into PDF happens only on export |

The main value is not faster page rendering. The value is making annotations structured, searchable, syncable, and shared across PDF, Web snapshot, and EPUB.

### Product architecture

PDF, Web snapshot, EPUB, and transcript annotations should share:

- one annotation list
- one tag/color/comment model
- one search and filter path
- one sync conflict model
- one AI summary/extraction path
- one import/export surface

Only `position` and rendering differ by attachment type.

## Zotero Reference Findings

Zotero stores annotations in SQLite table `itemAnnotations`, with fields equivalent to:

- parent attachment
- annotation type
- author name
- text
- comment
- color
- page label
- sort index
- position JSON
- external/read-only flag

In Zotero, the annotation parent points at the file attachment, not just the bibliographic/document item. OakReader should follow that relationship:

```text
Library item
  -> Attachment: PDF
      -> Annotations for that PDF
  -> Attachment: EPUB
      -> Annotations for that EPUB
  -> Attachment: Web snapshot
      -> Annotations for that snapshot
```

Its reader attachment type is derived from MIME:

- PDF: `application/pdf`
- EPUB: `application/epub+zip`
- Web snapshot: `text/html`

The reader open path loads child annotation items from the DB, converts each annotation to reader JSON, and passes that array into the reader. The reader save path calls back with JSON and saves each annotation via `saveFromJSON()`.

Observed Zotero position shapes:

```json
{
  "pageIndex": 0,
  "rects": [[0, 0, 100, 100]]
}
```

```json
{
  "type": "FragmentSelector",
  "conformsTo": "http://www.idpf.org/epub/linking/cfi/epub-cfi.html",
  "value": "epubcfi(/0)"
}
```

```json
{
  "type": "CssSelector",
  "value": "body"
}
```

Zotero also validates sort keys by format:

- PDF: `00015|002431|00000`
- EPUB: `00014|00002431`
- HTML snapshot: `0002431`

OakReader should reuse the spirit of this, but not copy Zotero's exact database shape. OakReader already has `items`, `attachments`, real columns, and JSON blobs. The right translation is `annotations.attachment_id -> attachments.id`, plus `annotations.position_json` for the per-format payload.

## Goals

- Keep imported source files clean during normal reading and annotation.
- Support PDF now, Web snapshot next, EPUB without another redesign.
- Store annotations as queryable rows.
- Let annotation edits persist independently from PDF saves.
- Preserve enough Zotero-compatible fields for import/export.
- Centralize all annotation mutation through one service/view model.
- Avoid duplicate source-of-truth state between PDFKit and storage.

## Non-goals

- Do not implement full Zotero item semantics.
- Do not make `annotations.jsonl` canonical.
- Do not embed annotations into PDFs on every save.
- Do not support collaborative real-time editing in the first pass.
- Do not solve all external PDF annotation round-trip behavior immediately.

## Data Model

Add an `annotations` table. This is Zotero-like JSON-in-DB storage, not JSONL-file storage.

```sql
CREATE TABLE annotations (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
    attachment_id TEXT NOT NULL REFERENCES attachments(id) ON DELETE CASCADE,

    -- Stable short key for Zotero-style JSON and local reader messages.
    key TEXT NOT NULL UNIQUE,

    -- highlight, underline, note, text, image, ink, area, strikeout
    type TEXT NOT NULL,

    author_name TEXT,
    text TEXT,
    comment TEXT,
    color TEXT NOT NULL DEFAULT '#ffd400',
    page_label TEXT,

    -- Format-specific ordering key. Text so it can match Zotero-style sort indexes.
    sort_index TEXT NOT NULL,

    -- pdf, html, epub, transcript
    position_kind TEXT NOT NULL,

    -- Format-specific JSON payload.
    position_json TEXT NOT NULL,

    -- Optional rendering hints such as dashed border, opacity, fill, line width.
    -- Canonical meaning stays in type + position_json; style is presentation.
    style_json TEXT,

    -- external_pdf, zotero, mendeley, oakreader, etc.
    source TEXT NOT NULL DEFAULT 'oakreader',
    source_key TEXT,
    is_external INTEGER NOT NULL DEFAULT 0,

    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    deleted_at TEXT
);

CREATE INDEX idx_annotations_attachment_sort
    ON annotations(attachment_id, deleted_at, sort_index);

CREATE INDEX idx_annotations_item_updated
    ON annotations(item_id, updated_at);

CREATE UNIQUE INDEX idx_annotations_source
    ON annotations(source, source_key)
    WHERE source_key IS NOT NULL;
```

Add annotation tags either with a narrow join table or by reusing OakReader's existing property system later. First pass can defer annotation tags.

```sql
CREATE TABLE annotation_tags (
    annotation_id TEXT NOT NULL REFERENCES annotations(id) ON DELETE CASCADE,
    option_id TEXT NOT NULL REFERENCES property_options(id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    PRIMARY KEY (annotation_id, option_id)
);
```

## Canonical Model

```swift
struct AnnotationRecord: Codable, Identifiable, Hashable {
    var id: UUID
    var userId: String
    var itemId: UUID
    var attachmentId: UUID
    var key: String
    var type: AnnotationType
    var authorName: String?
    var text: String?
    var comment: String?
    var colorHex: String
    var pageLabel: String?
    var sortIndex: String
    var positionKind: AnnotationPositionKind
    var positionJSON: String
    var styleJSON: String?
    var source: AnnotationSource
    var sourceKey: String?
    var isExternal: Bool
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}
```

```swift
enum AnnotationType: String, Codable {
    case highlight
    case underline
    case strikeout
    case note
    case text
    case image
    case ink
    case area
}

enum AnnotationPositionKind: String, Codable {
    case pdf
    case html
    case epub
    case transcript
}
```

## Position Payloads

## Annotation Semantics

`comment` is not a separate annotation type. It is an optional field on every annotation.

Use annotation `type` to describe the visible/interaction behavior, and use `position_json` to describe what the annotation is anchored to.

| User action | Stored type | Position | Fields |
|---|---|---|---|
| Select text -> highlight | `highlight` | text range / PDF rects | `text`, optional `comment` |
| Select text -> underline | `underline` | text range / PDF rects | `text`, optional `comment` |
| Select text -> add comment only | `note` | text range anchor | `text`, `comment` |
| Select area -> add rectangle | `area` | rectangle/region | optional `comment` |
| Select area -> add comment | `area` or `note` | rectangle/region | `comment` |
| Click page -> sticky note | `note` | point or small rect | `comment` |
| Add visible text box | `text` | rect | `text`, optional `comment` |
| Draw ink | `ink` | paths | optional `comment` |

This keeps the model flexible:

- A highlight can have a comment.
- An area selection can have a comment.
- A pure comment is a `note` annotation.
- A visible text box is `text`, not `comment`.

### Area Annotation Visuals

Area annotations should have a visible but quiet anchor. Without one, a comment attached to a region is hard to rediscover later.

Recommended default for an area comment:

```json
{
  "borderStyle": "dashed",
  "borderWidth": 1.5,
  "borderOpacity": 0.55,
  "fillColor": null,
  "fillOpacity": 0.0
}
```

Interaction states:

- normal: light dashed outline
- hover: stronger outline and subtle fill
- selected: solid handles plus comment popover
- export with annotations: render the dashed outline unless the user chooses "comments only"

Do not model this as a separate line annotation. Store it as one `area` annotation with a rectangle in `position_json` and optional style hints in `style_json`. This keeps undo, deletion, selection, export, and comments attached to one logical annotation.

### PDF

Use PDF page coordinates. Store rects in Zotero-compatible `[left, bottom, right, top]` shape.

```json
{
  "pageIndex": 12,
  "rects": [[231.284, 402.126, 293.107, 410.142]],
  "quadPoints": [[231.284, 402.126, 293.107, 402.126, 231.284, 410.142, 293.107, 410.142]],
  "rotation": 0
}
```

For ink:

```json
{
  "pageIndex": 12,
  "width": 2.0,
  "paths": [[10, 20, 30, 40, 50, 60]]
}
```

For image/area:

```json
{
  "pageIndex": 12,
  "rects": [[100, 200, 300, 450]],
  "width": 200,
  "height": 250
}
```

### Web Snapshot

Use Web Annotation style selectors. CSS selector alone is too brittle, so store selector plus text quote and text offsets.

```json
{
  "selectors": [
    {
      "type": "CssSelector",
      "value": "article > p:nth-of-type(4)"
    },
    {
      "type": "TextQuoteSelector",
      "exact": "selected text",
      "prefix": "text before ",
      "suffix": " text after"
    },
    {
      "type": "TextPositionSelector",
      "start": 1520,
      "end": 1583
    }
  ],
  "rectsCache": [[120, 340, 440, 358]]
}
```

Resolution order:

1. Text quote selector
2. Text position selector
3. CSS selector
4. Cached rects for best-effort visual fallback

### EPUB

Use EPUB CFI as the primary anchor, with text quote as recovery data. Reflow means rects must be treated as cache only.

```json
{
  "spineIndex": 5,
  "href": "chapter-05.xhtml",
  "selectors": [
    {
      "type": "FragmentSelector",
      "conformsTo": "http://www.idpf.org/epub/linking/cfi/epub-cfi.html",
      "value": "epubcfi(/6/14!/4/2/8,/1:12,/1:48)"
    },
    {
      "type": "TextQuoteSelector",
      "exact": "selected EPUB text",
      "prefix": "before ",
      "suffix": " after"
    }
  ],
  "rectsCache": [[80, 220, 310, 240]]
}
```

### Transcript / Video

Future shape:

```json
{
  "startMs": 91320,
  "endMs": 105800,
  "cueIndex": 42,
  "textStart": 8,
  "textEnd": 64
}
```

## Sort Index

Use a text `sort_index` so each format can preserve stable ordering.

Recommended formats:

- PDF: `PPPPP|CCCCCC|YYYYY`
- EPUB: `SSSSS|CCCCCCCC`
- HTML snapshot: `CCCCCCC`
- Transcript: `MMMMMMMMMM|CCCC`

Where:

- `P` is page index
- `S` is spine index
- `C` is character/order offset
- `Y` is y-position or intra-page tiebreaker
- `M` is millisecond timestamp

Sort indexes are optimization and display order, not the only anchor. Position JSON remains authoritative for locating the annotation.

## Runtime Architecture

```text
SQLite annotations table
        |
        v
AnnotationStore
        |
        v
AnnotationViewModel / AnnotationCoordinator
        |
        +--> PDFAnnotationProjector      -> PDFKit PDFAnnotation
        +--> WebAnnotationProjector      -> WKWebView JS overlay / DOM ranges
        +--> EPUBAnnotationProjector     -> EPUB CFI / DOM ranges
        +--> TranscriptProjector         -> time range highlighting
```

### AnnotationStore

Responsibilities:

- load annotations by `attachment_id`
- upsert annotations
- soft-delete annotations
- restore annotations
- query by item, tag, color, text, comment
- provide reader JSON for projection
- import/export Zotero-compatible JSON

Suggested API:

```swift
protocol AnnotationStore {
    func annotations(for attachmentId: UUID, includeDeleted: Bool) throws -> [AnnotationRecord]
    func annotation(id: UUID) throws -> AnnotationRecord?
    func upsert(_ annotation: AnnotationRecord) throws
    func upsertBatch(_ annotations: [AnnotationRecord]) throws
    func softDelete(id: UUID) throws
    func annotations(matching query: AnnotationQuery) throws -> [AnnotationRecord]
}
```

### Projectors

Projectors convert between canonical annotation rows and runtime rendering objects.

```swift
protocol AnnotationProjector {
    associatedtype RuntimeAnnotation

    func project(_ record: AnnotationRecord) throws -> RuntimeAnnotation
    func capture(_ runtime: RuntimeAnnotation) throws -> AnnotationRecord
    func removeRuntimeAnnotation(key: String)
    func updateRuntimeAnnotation(_ record: AnnotationRecord) throws
}
```

PDF projector:

- converts DB row to `PDFAnnotation`
- stores OakReader annotation key in PDFAnnotation user metadata if possible
- updates PDFKit immediately after DB save
- never treats PDFKit as canonical after migration

Web/EPUB projectors:

- inject annotations via JS bridge
- capture selection ranges from JS
- send canonical JSON back to Swift
- use overlay/span rendering without modifying stored HTML/EPUB files

## Save Semantics

### Normal annotation edit

1. User creates/edits/deletes annotation.
2. ViewModel creates canonical annotation update.
3. `AnnotationStore` writes DB transaction.
4. Projector updates visible runtime annotation.
5. PDF/HTML/EPUB source file remains unchanged.

Annotation edits should not call `pdfDocument.dataRepresentation()` and should not mark the PDF file dirty.

### PDF document mutation

Real PDF edits still use the PDF document save path:

- page rotation
- page deletion
- form/widget edits
- redaction
- compression
- encryption
- explicit flattening

### Export annotated PDF

Explicit export path:

1. Copy or rewrite clean PDF.
2. Load annotations for attachment.
3. Project supported annotations into a temporary `PDFDocument`.
4. Preserve widgets and links.
5. Write output PDF.

This keeps everyday annotation editing light and moves expensive PDF serialization to explicit export.

## Migration Strategy

### Phase 1: Centralize mutation

Before adding DB persistence, route all annotation mutations through `AnnotationViewModel`:

- `AnnotationPropertyPanel`
- `AreaSelectionPopupPanel`
- `TextSelectionPopupPanel`
- `PDFViewCoordinator`
- `UndoCoordinator`
- `AnnotationListView`

No view or coordinator should directly mutate a `PDFAnnotation` without going through the annotation layer.

### Phase 2: Add DB schema and store

Add:

- `AnnotationRecord`
- `AnnotationStore`
- `AnnotationPosition`
- `CatalogDatabase` migration
- attachment-level annotation query helpers

Sidebar should read from `AnnotationStore`, not page scans.

### Phase 3: PDF runtime projection

For managed PDFs:

- open PDF
- load DB annotations
- project them to PDFKit
- create/edit/delete writes DB first, then updates PDFKit
- annotation edits do not dirty the PDF file

For unmanaged PDFs:

- keep current embedded behavior until imported
- optional prompt: "Import into library to enable clean annotations"

### Phase 4: Existing embedded annotation migration

On first managed open:

1. Scan PDF for existing non-widget, non-link annotations.
2. Create DB rows with `source = 'embedded_pdf'`.
3. Assign stable generated keys.
4. After successful DB transaction, strip migrated annotations from the managed PDF copy only.
5. Preserve widgets and links.
6. Keep a one-time backup or recovery marker.

Do not strip before DB commit.

### Phase 5: Web snapshot annotations

Implement text selection capture in `WKWebView`:

- compute text quote selector
- compute text position selector
- compute CSS selector fallback
- render annotations with JS/CSS overlay
- persist rows in the same `annotations` table

### Phase 6: EPUB annotations

Add EPUB reader support around:

- spine item identity
- EPUB CFI generation/resolution
- text quote fallback
- reflow-aware rect cache invalidation

EPUB annotations should use the same store and sidebar as PDF/Web.

### Phase 7: Zotero import/export

Support two adapters:

- Zotero reader JSON: unprefixed `type`, `text`, `comment`, `color`, `position`
- Zotero item/API JSON: prefixed `annotationType`, `annotationText`, etc.

Import should preserve:

- `key` as `source_key`
- `isExternal`
- `sortIndex`
- `pageLabel`
- tags when possible

Export should generate Zotero-compatible reader JSON from OakReader records.

## Affected OakReader Areas

- `OakReader/Models/AnnotationModel.swift` - replace runtime-only snapshot with canonical model or add separate canonical model
- `OakReader/Models/DatabaseRecords.swift` - add `AnnotationRecord`
- `OakReader/Services/CatalogDatabase.swift` - add annotation migrations and indexes
- `OakReader/Services/AnnotationStore.swift` - new DB service
- `OakReader/ViewModels/AnnotationViewModel.swift` - becomes mutation boundary and projection coordinator
- `OakReader/ViewModels/DocumentViewModel.swift` - expose active attachment ID/key, not only item storage key
- `OakReader/Document/OakReaderDocument.swift` - stop using PDF save for annotation-only edits
- `OakReader/App/AppState.swift` - pass item and attachment identity into document tabs
- `OakReader/Views/Sidebar/AnnotationListView.swift` - query store rather than scan PDF pages
- `OakReader/Views/Annotations/AnnotationPropertyPanel.swift` - route all edits through `AnnotationViewModel`
- `OakReader/Views/Viewer/PDFViewCoordinator.swift` - route annotation context menu changes through `AnnotationViewModel`
- `OakReader/Views/Viewer/AreaSelectionPopupPanel.swift` - route area annotations through `AnnotationViewModel`
- `OakReader/Coordinators/UndoCoordinator.swift` - undo/redo DB annotation operations, then update projection
- Web snapshot viewer - add JS selection/projector bridge
- Future EPUB reader - add CFI/projector bridge

## Risks

### Duplicate rendering

If migrated embedded PDF annotations remain in the PDF while DB annotations are projected, users will see duplicates. Migration needs a clear marker and should strip only after DB commit.

### PDFKit metadata limits

PDFKit may not reliably preserve custom annotation keys. The DB key is canonical; PDFAnnotation metadata is only a lookup optimization.

### Selection anchors can rot

HTML and EPUB text selectors may fail if content changes. Mitigate with multiple selectors:

- EPUB CFI
- Text quote
- text offset
- CSS selector
- cached rects

### Undo semantics

Undo must reverse DB operations and projection operations together. The old "remove PDFAnnotation from page" undo path is no longer enough.

### External annotation imports

Annotations imported from embedded PDFs or Zotero may have ownership/read-only semantics. Keep `source`, `source_key`, and `is_external` separate so OakReader can decide when to allow edits.

## Open Questions

- Should `attachment_id` be added explicitly to `DocumentViewModel`, or should it always derive from `LibraryItem.primaryAttachment`?
- Should annotation tags reuse the item property system immediately, or start with a simpler `annotation_tags` join?
- Should embedded PDF annotation migration strip from the managed PDF automatically, or ask once per document?
- Should comments use Markdown/plain text now, or remain plain text until note integration is clearer?
- Should `key` be 8-character Zotero style, UUID-derived, or both?

## Recommendation

Implement the unified annotation store in phases. Do not build the PDF-only JSONL architecture.

The right architecture is:

```text
SQLite annotations table = canonical storage
AnnotationStore = persistence and query API
PDFAnnotation / DOM overlay / EPUB CFI = runtime projection
Zotero JSON / JSONL = import-export format
```

This design makes PDF annotation edits lighter, but its real payoff is shared annotation behavior across PDF, Web snapshots, EPUB, and future transcript/video readers.
