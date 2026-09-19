# Portable Core — the Windows track

Status: **started**. The CJK tokenizer blocker is resolved and verified; the
rest of the catalog port has not begun.

Goal: ship a Windows OakReader. Strategy is the one
[node-backend-migration.md](node-backend-migration.md) already committed to —
thin native shells per platform over one shared Node core — carried from the AI
stack (done) to the library catalog (this document).

## Why the catalog is the whole job

The AI half is finished and live-verified: protocol v2, real streaming against
Anthropic, and a bidirectional client-tool round-trip. What is still Swift-only
is everything a Windows client would also need:

| Piece | Size | Portability |
|---|---|---|
| GRDB catalog (19 files) | 5,021 lines | schema is plain SQLite — portable |
| Importers (`ImportService+*`) | 1,520 lines | **PDF path depends on PDFKit** |
| FTS index (`search.sqlite`) | 205 MB, 201,707 chunks | **regenerable, not migratable** |
| Migrations | 10 | re-express in the core |

## Blocker 1 — the custom FTS5 tokenizer — RESOLVED

`CJKBigramTokenizer` is a real FTS5 tokenizer registered through GRDB's
`FTS5WrapperTokenizer`. Registering one requires the SQLite **C API**
(`sqlite3_fts5_create_tokenizer`), which neither `node:sqlite` nor
better-sqlite3 exposes to JavaScript.

Measured, not assumed: Node opens the existing `search.sqlite` and reads rows
fine (`SELECT count(*)` → 201,707), but every `MATCH` fails with
`no such tokenizer: cjk_bigram`. **The existing index cannot be read by a Node
client at all.** It must be rebuilt, which is acceptable because `FTSDatabase`
already documents it as "fully regenerable from source content".

Resolution: move the identical expansion into userland
(`web/backend/src/catalog/tokenizer.ts`) and let plain `unicode61` tokenize the
result. Same token stream in, same ranking out. The invariant is that expansion
must run at **both** index and query time — Swift's `accept()` ignores its
`FTS5Tokenization` argument, so it behaves identically for both.

Validation on the real corpus (201,707 chunks, 12 highest-frequency CJK terms,
2- and 3-character): FTS results **byte-identical** to a `LIKE '%term%'` scan —
zero false negatives, zero false positives. Reindexing the full corpus in Node
took **5.8 s**, so the one-time rebuild is a non-event. Locked in by
`web/backend/test/tokenizer.test.mjs`.

## Blocker 2 — PDF text extraction — OPEN

`ImportService.swift` and `ImportService+PDF.swift` extract text via PDFKit. A
Node core needs `pdfjs-dist` instead, and extraction **will** differ — different
text-run joining, different whitespace, different reading order on multi-column
pages. Chunk boundaries shift, so citations anchored to chunk text
(see [citation-chunk-id-redesign]) can drift.

Not yet decided. Options, cheapest first:
1. Keep PDF extraction in the Swift shell, ship text to the core. Windows then
   needs its own extractor — the divergence moves rather than disappears.
2. Move to `pdfjs-dist` on both platforms. One behavior everywhere, but it
   reindexes and re-anchors an existing library.
3. Dual-run on a sample of the real library, diff the chunk output, and decide
   with numbers.

Do (3) before choosing. Nothing else in the port depends on this.

## Phases

- **P0 — tokenizer parity.** ✅ done, tested.
- **P1 — schema + read path.** Re-express the 10 migrations in the core; serve
  read-only `library/*` protocol commands (list items, collections, tags,
  search). Swift keeps writing; the core only reads. Diff core results against
  Swift results on the live library before going further.
- **P2 — write path.** Moves `LibraryItemStore`, `AnnotationStore`,
  `LibraryCollectionStore` etc. behind the protocol. One writer at a time —
  never both processes writing the same SQLite file.
- **P3 — importers.** Blocker 2 must be settled first.
- **P4 — Windows shell.** Only reachable after P1–P3.

## Rules

- **The core never owns the UI.** Raycast's actual design is React → custom
  reconciler → *native* views, not React in a webview. The macOS shell stays
  SwiftUI/AppKit and PDFKit; see the Electron analysis in the session notes for
  why a webview-hosted PDF surface is a regression here.
- **Back up before touching the live DB.** `~/OakReader-Dev/library.sqlite` is
  real data with real history.
- **Swift and the core must not write concurrently.** Until P2 lands, the core
  opens the catalog read-only.
