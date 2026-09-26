# Architecture Decision Records

Architectural decisions made during OakReader development, extracted from 52 Claude Code sessions (Apr 22 – May 1, 2026).

---

## Data Layer & Storage

### ADR-001: GRDB over SwiftData/CoreData for Local Database
- **Context**: OakReader was initially built with SwiftData for library metadata. Security-scoped bookmarks kept going stale after rebuilds/updates due to code signing identity changes, causing "not a valid PDF" bugs.
- **Decision**: Replace SwiftData with GRDB.swift (SQLite wrapper) for all library metadata storage. Remove sandbox entirely. Copy PDFs into managed storage instead of using security-scoped bookmarks.
- **Alternatives Considered**: SwiftData (original, rejected due to sandbox/bookmark issues), CoreData (not explicitly discussed), ElectricSQL (discussed as future Phase 2 sync layer)
- **Rationale**: GRDB provides direct SQLite control, Postgres-compatible schema design (UUIDs, ISO8601 timestamps, user_id fields) for future ElectricSQL sync, migrations, and SwiftUI-compatible observation. Complex migrations are trivial in SQL vs painful in SwiftData. SwiftData generates opaque schema that can't be guaranteed to match Postgres. SwiftData loads all objects into memory during migration (OOM risk at 100k items).

### ADR-002: Filesystem-Based Document Storage (Zotero Model)
- **Context**: Designing how to store PDFs, chat sessions, and metadata after removing the sandbox.
- **Decision**: Adopt Zotero's storage model: SQLite as source of truth for metadata, filesystem (`~/OakReader/storage/{8-char-key}/`) for binary files (PDFs, covers, chat JSONL, note attachments).
- **Alternatives Considered**: Keeping PDFs in-place with bookmarks (rejected), storing everything in SQLite (rejected for large files), iCloud container (rejected for complexity), per-document `metadata.json` files (rejected — querying thousands of JSON files is slow)
- **Rationale**: SQLite for metadata provides fast queries, ACID transactions, and FTS5 search. Filesystem for binaries avoids SQLite blob overhead. 8-char random directory keys (Zotero pattern) prevent filename conflicts. The managed storage approach ("import by copy") eliminates all bookmark/reference issues.

### ADR-003: Remove App Sandbox, Distribute Directly
- **Context**: Security-scoped bookmarks kept breaking on development rebuilds. The sandbox was the root cause of the "not a valid PDF" bug.
- **Decision**: Remove the macOS app sandbox entirely. Distribute the app directly (not through Mac App Store), like Zotero, Obsidian, and VS Code.
- **Alternatives Considered**: Keeping sandbox with improved bookmark handling (rejected as fundamentally broken for dev workflow), Mac App Store distribution (requires sandbox)
- **Rationale**: Most serious document/research apps (Zotero, Obsidian, DEVONthink, Calibre, VS Code) use direct distribution without sandbox. Eliminates the bookmark permission bugs entirely. User-visible data directory (`~/OakReader/`) is easier to backup.

### ADR-004: UUID in DB + 8-char Random Key for Storage Directories
- **Context**: Deciding whether to use UUIDs or short random keys for both database IDs and filesystem directory names.
- **Decision**: Use UUID for database `id` column (ElectricSQL sync safety) and an 8-char random `storage_key` column for filesystem directory names. Cloud sync keys use UUID path: `{user-id}/{document-uuid}/{filename}`.
- **Alternatives Considered**: UUID for both (simpler but long paths), 8-char for both (collision risk in distributed sync)
- **Rationale**: Zotero uses this same hybrid pattern. Short keys make filesystem paths human-friendly. UUIDs in DB ensure global uniqueness for multi-device sync.

### ADR-005: ElectricSQL for Future Cloud Sync
- **Context**: Discussion about cloud backup/sync for reading data across devices.
- **Decision**: Design schema to be ElectricSQL-compatible from day one (UUIDs, timestamps set in app code not SQLite triggers, user_id on all tables, no SQLite-specific features in core tables), but defer sync implementation. Cloud sync planned as future paid feature. File sync via Google Cloud Storage keyed by `{user-id}/{doc-uuid}/{filename}`.
- **Alternatives Considered**: iCloud Drive (works for files but SQLite corruption risk), iCloud Drive + CloudKit (complex), WebDAV (not discussed in depth), custom sync (more work)
- **Rationale**: Local-first with SQLite provides immediate offline capability. ElectricSQL can layer sync on top later without schema changes. Cloud sync as paid feature is a viable commercial strategy (PDF Expert, MarginNote do the same). FTS5 stays local-only since Postgres has native full-text search.

### ADR-006: Schema Rename from "documents" to "items"
- **Context**: The app handles PDFs, web pages, YouTube videos, podcasts. "Document" implies a file, but the core abstraction is a knowledge item.
- **Decision**: Rename tables: documents→items, document_collections→collection_items, document_tags→item_tags, reference_metadata→citations, chat_sessions→conversations, documents_fts→items_fts. Column renames: document_type→item_type, original_file_name→file_name, date_last_opened→last_opened_at, is_in_inbox→is_inbox.
- **Rationale**: Better semantic accuracy for a multi-content-type library. The rename is cheaper now (pre-launch) than later.

---

## Data Modeling

### ADR-007: CSL JSON as Canonical Reference Data Format
- **Context**: Adding reference/citation management. Studied Zotero's EAV schema (36 item types, 123 fields, 29 creator types, 5 tables with 3-way JOINs).
- **Decision**: Store bibliographic metadata as CSL JSON blobs in a single `reference_metadata` table, with indexed columns (doi, year, csl_type, container_title) for query performance. No separate creators table.
- **Alternatives Considered**: Zotero's EAV schema (rejected as too complex — 5 tables, 3-way JOINs), separate creators table (rejected as redundant since CSL JSON already contains structured name data)
- **Rationale**: CSL JSON is the open standard that Zotero, Mendeley, and Paperpile all internally map to. Storing it directly means native interoperability, no schema changes when CSL adds fields, and simpler implementation (1 table vs 5).

### ADR-008: Reject EAV/Property System in Favor of Real Columns + Tags + CSL JSON
- **Context**: Extensive discussion about whether to implement an Entity-Attribute-Value (EAV) property system like Notion/Airtable, or Zotero's itemData EAV pattern.
- **Decision**: Use real indexed columns for structured fields (status, rating, item_type, year, doi), CSL JSON blob for bibliographic fields, and flat tags for free-form metadata. No EAV tables.
- **Alternatives Considered**: Full EAV property system with property_definitions/property_values tables (rejected), Zotero-style closed EAV (rejected — solved the 80-column problem that CSL JSON already handles), Notion-style open EAV (rejected — premature for product stage)
- **Rationale**: EAV turns simple `WHERE status = 'unread'` into multi-join queries. CSL JSON already stores the 80+ varying bibliographic fields. Real columns are fast, indexable, and compatible with ElectricSQL/Postgres sync. Zotero used EAV in 2006 because JSON columns weren't available; modern SQLite has JSON support.

### ADR-009: Tag Groups for Faceted Tags at Scale (50-100k Items)
- **Context**: User's library is 50-100k items. At that scale, flat tags (500+) become unmanageable.
- **Decision**: Create a `tag_groups` table with id, name, sort_order, and add `group_id` FK on tags (nullable). Tag groups are always multi-select. Single-select concepts (status, rating) stay as real columns.
- **Alternatives Considered**: group_name text column on tags (rejected — typo duplicates, rename requires bulk update), typed tag groups with string/number/single-select (rejected — reinvents EAV), keeping tags flat (rejected at 50-100k scale)
- **Rationale**: A normalized table avoids string-matching problems, supports rename/reorder/delete cleanly, prevents typo duplicates, and scales to 500+ tags organized into Topic/Venue/Method/Project groups.

### ADR-010: Chat Session Metadata in GRDB with JSONL for Message Content
- **Context**: No way to browse or switch between past AI chat conversations.
- **Decision**: Use GRDB `chat_sessions` table for session metadata (title, message count, timestamps), keep JSONL files for actual message content. Make `document_id` nullable for library-wide (no-document) chat sessions.
- **Alternatives Considered**: Storing everything in JSONL (rejected — no efficient querying), storing everything in GRDB (rejected — JSONL already works for message content and is simpler for streaming)
- **Rationale**: Hybrid approach leverages GRDB for fast listing/filtering of sessions while keeping JSONL for append-friendly message storage during streaming.

### ADR-011: Notes Storage — DB Metadata + Filesystem Content
- **Context**: Designing how to store notes attached to documents.
- **Decision**: Store note metadata (title, dates, pinned status) in SQLite `notes` table. Store note content as `.md` files at `~/OakReader/storage/{storageKey}/notes/{noteId}.md`. Image attachments at `~/OakReader/storage/{storageKey}/notes/attachments/`.
- **Rationale**: Follows same pattern as chat sessions (JSONL files + DB metadata). Markdown files are human-readable and portable.

### ADR-012: Annotation Storage in Database, Not in Files
- **Context**: Studying how Zotero handles annotations across PDF, EPUB, and HTML snapshot formats.
- **Decision**: Follow Zotero's approach: store annotations in database (`itemAnnotations` table), not by modifying the original files. Position data is format-specific JSON (PDF: page+rects, HTML: CSS selector+text offset).
- **Alternatives Considered**: Modifying original files (rejected to keep files clean and enable sync), JS injection annotation layer on WKWebView (complex)
- **Rationale**: Original PDF/HTML files are never polluted, annotations can sync across devices independently, and a unified annotation system works across all document formats.

### ADR-013: Collections as Logical Groupings (Not Filesystem Folders)
- **Context**: Whether collections should be filesystem-based or logical.
- **Decision**: Collections are logical groupings via GRDB `document_collections` many-to-many join table. Files stored in flat random-keyed directories. An item can belong to multiple collections without file duplication.
- **Alternatives Considered**: Filesystem-based collections (Zotero, Mendeley, Papers, EndNote all rejected this approach)
- **Rationale**: Every serious reference manager uses logical collections. Renaming/restructuring is instant. Deletion from collection doesn't delete the file.

---

## Multi-Document-Type Architecture

### ADR-014: TabContent Enum for Multi-Document-Type Support
- **Context**: Supporting both PDF and HTML documents in the tab system.
- **Decision**: Replace `let document: OakReaderDocument` with a `TabContent` enum (`case pdf(OakReaderDocument)`, `case html(HTMLDocument)`) in `DocumentTab`.
- **Rationale**: Type-safe dispatching for viewer routing, file operations, and AI context extraction. Allows `ContentView` to use a simple `switch` to render the appropriate viewer.

### ADR-015: Unified "embed" Document Type for Live Content
- **Context**: Separate `youtubeVideo` and `podcast` document types were overly specific. Podcast code was unused.
- **Decision**: Replace both with a single `embed` type. Remove all podcast code. Chrome extension emits `type: "embed"` for YouTube pages. X.com/Twitter stays as `html` (static content).
- **Alternatives Considered**: Keeping separate types (rejected — podcast support was premature/unused), treating embeds as snapshots with whitelisted domains (rejected — mixes offline/online semantics)
- **Rationale**: Embeds are fundamentally different from snapshots: snapshots promise offline, self-contained content; embeds are live wrappers requiring internet. `embed` is generic and can accommodate future embed types.

### ADR-016: Inbox as Email-Style Triage Queue
- **Context**: Inbox showed all items or items with no collections. It should only show items from browser extensions.
- **Decision**: Inbox works like email: items from extensions get `isInInbox = true`, moving to a collection clears the flag. Inbox is a "to-process" queue.
- **Alternatives Considered**: Permanent source filter (items always show in inbox regardless of organization), collection-empty heuristic (unintuitive — manually opened PDFs appear)
- **Rationale**: Email inbox model is well-understood. Items enter inbox via extension, leave when organized. Clear semantic meaning.

---

## Web Snapshot Architecture

### ADR-017: Chrome Extension + Local HTTP Server for Web Snapshots
- **Context**: User wanted Zotero-style web page snapshot capture.
- **Decision**: Chrome extension captures pages using SingleFile format (self-contained HTML). Extension POSTs to a local HTTP server in OakReader (NWListener on localhost:23119, same port as Zotero). Store both original HTML and auto-converted PDF.
- **Alternatives Considered**: Custom URL scheme (less reliable), Native Messaging Host (more complex setup), HTML-only storage (would need separate annotation system), PDF-only storage (loses interactivity)
- **Rationale**: Zotero's local HTTP server approach is the most reliable for extension-to-app communication. Dual format gives best of both worlds. SingleFile strips scripts for security.

### ADR-018: SingleFile for Self-Contained HTML Snapshots via Vite
- **Context**: Chrome extension captured raw HTML where images remained as URL references but WKWebView blocked external requests.
- **Decision**: Use `single-file-core` as npm dependency, imported directly via dynamic `import()` in the content script. Vite/WXT bundles it automatically. No separate rollup step.
- **Alternatives Considered**: Raw HTML capture (images don't load), rollup + background script injection (unnecessarily complex), SingleFile-Lite as git submodule (Zotero's approach — simpler but less integrated)
- **Rationale**: Vite already handles ES module bundling for content scripts. Adding a separate rollup step was unnecessary complexity. Dynamic import ensures SingleFile's ~834KB bundle only loads when the user saves.

### ADR-019: WKWebView Security Sandboxing for Snapshots
- **Context**: Rendering potentially untrusted captured web content in-app.
- **Decision**: WKWebView with strict security: load HTML via `loadFileURL` scoped to storage dir only, block all external HTTP/HTTPS via `WKContentRuleList` (compiled async to avoid main-thread deadlock), block non-file-URL navigation via `WKNavigationDelegate`.
- **Rationale**: Dual-layer protection ensures no network requests from captured content. Async content rule compilation prevents the classic main-thread deadlock.

### ADR-020: WXT + TypeScript for Chrome Extension
- **Context**: Initial Chrome extension was vanilla JavaScript.
- **Decision**: Replace with WXT (Manifest V3) + TypeScript scaffolded with pnpm. Renamed directory to kebab-case for monorepo conventions.
- **Alternatives Considered**: Vanilla JS (initial), Nx monorepo manager (rejected — overkill for one JS package with a primarily Swift project)
- **Rationale**: WXT provides HMR dev mode, TypeScript type safety, and a cleaner build pipeline. Nx has no understanding of xcodebuild/XcodeGen/Swift.

---

## Note Editor

### ADR-021: NSTextView + Regex Highlighting over WKWebView/CodeMirror for Notes
- **Context**: The MarkdownEditor package (CodeMirror 6 in WKWebView) had persistent bugs: code block detection failures, horizontal overflow, backtick input interference.
- **Decision**: Replace WKWebView-based editor with MiaoYan-style plain NSTextView + regex-based syntax highlighting + separate WKWebView preview. Three modes: Edit/Preview/Split.
- **Alternatives Considered**: MarkdownEditor/CodeMirror 6 (rejected for bugginess), MarkupEditor/ProseMirror (rejected for no math support and HTML-only storage), MarkEdit (rejected as code editor with no inline preview), SwiftDown (too simple), custom Tiptap/ProseMirror (too much work)
- **Rationale**: NSTextView with regex highlighting is more reliable and native-feeling than WKWebView. MiaoYan proved this approach works well.

### ADR-022: WKWebView with MiaoYan CSS/JS Bundle for Note Preview
- **Context**: Textual-based SwiftUI preview was too limited (no custom CSS, basic code blocks, no image zoom).
- **Decision**: Switch note preview from Textual StructuredText to WKWebView with MiaoYan's CSS/JS bundle (stripped from ~6MB to ~468KB), using cmark-gfm for markdown-to-HTML conversion. Kept: highlight.js, KaTeX, Lightense, Heti. Stripped: mermaid, d3, markmap, plantuml, emoji, tocbot.
- **Alternatives Considered**: Textual StructuredText (rejected for limited styling control, no diagram support)
- **Rationale**: WKWebView allows full CSS control for typsography. MiaoYan's proven bundle provides all features out of the box.

### ADR-023: Force TextKit 1 for Cursor Height Fix on macOS 15
- **Context**: Empty lines in the markdown editor had overly tall cursors. The `drawInsertionPoint` override wasn't being called on macOS 15 (TextKit 2 default).
- **Decision**: Force TextKit 1 mode by accessing `textView.layoutManager` during setup. This triggers the documented fallback to TextKit 1 where `drawInsertionPoint(in:color:turnedOn:)` is actually invoked.
- **Alternatives Considered**: TextKit 2 with lineSpacing-only paragraph style (worked for one iteration but had other issues), adjusting paragraph style (insufficient root cause was TextKit 2 bypassing drawInsertionPoint)
- **Rationale**: macOS 15 defaults to TextKit 2, which draws the insertion point via a separate `NSTextInsertionIndicator` subview, completely bypassing the override.

### ADR-024: Slash Command Menu for Note Editor
- **Context**: User wanted Notion/Obsidian-style `/` command support.
- **Decision**: Implement a filtering popup menu triggered by `/` at line start. Type to filter (e.g., `/h1`, `/code`). Arrow keys to navigate, Enter to select.
- **Rationale**: Obsidian/Notion-style slash commands are a well-established UX pattern for markdown editors.

### ADR-025: [[Reference]] Links for Bidirectional Note-Document Navigation
- **Context**: When users select text from a PDF and add it to a note, the note should link back to the source location.
- **Decision**: Use `[[Page X]]` syntax in notes. In edit mode, highlighted in teal with click-to-navigate. In preview mode, rendered as clickable links via `oak-ref://` URL scheme.
- **Rationale**: The `[[]]` syntax is familiar from Obsidian/Roam for bidirectional linking.

### ADR-026: Replace NSOpenPanel Image Upload with Clipboard Paste
- **Context**: The "Insert Image" button in Notes toolbar opened an NSOpenPanel file picker, deemed useless.
- **Decision**: Remove the photo button entirely. Add `paste(_:)` override in `MarkdownNSTextView` that saves image data and inserts `![paste](relativePath)` at cursor.
- **Rationale**: More natural workflow: users paste from clipboard (Cmd+V) or use area selection popup's "Add to Note".

---

## AI Chat

### ADR-027: Textual Library for Rich Markdown + LaTeX Chat Rendering
- **Context**: AI chat used `AttributedString(markdown:)` with inline-only rendering. No code blocks, tables, lists, headings, or LaTeX math.
- **Decision**: Use Textual (gonzalezreal) library with `StructuredText(markdown:syntaxExtensions:[.math])`. Bump macOS deployment target from 14.0 to 15.0 (Textual requirement).
- **Alternatives Considered**: WKWebView + cmark-gfm + KaTeX + highlight.js (overkill for chat bubbles), MarkdownView/LiYanan2004 (poor streaming — re-parses full AST on each update), RaTeX (LaTeX only, no markdown), MarkdownUI (gonzalezreal's earlier library)
- **Rationale**: Textual provides all-in-one: full CommonMark, LaTeX math, code highlighting, native SwiftUI (no WebView), designed for incremental updates (streaming friendly). MarkdownView was specifically rejected because it re-parses the full AST on every content change, causing CPU issues during streaming.

### ADR-028: Separate Read-Only Renderer and WYSIWYG Editor for Markdown
- **Context**: Whether having Textual for chat preview and a separate MarkdownEditor for notes was redundant.
- **Decision**: Keep them as separate components. Textual (SwiftUI-native) for read-only chat bubble rendering, WKWebView-based editor for note editing.
- **Rationale**: Different performance profiles: chat needs many lightweight instances with streaming support (WKWebView per message would be terrible performance). Editor needs full editing capabilities.

### ADR-029: Streaming Text Animation with Line-by-Line Reveal
- **Context**: AI chat streaming was abrupt — content jumped as delta chunks arrived.
- **Decision**: Use an `@Observable class StreamRevealController` with a 30fps timer that reveals content line-by-line. Adaptive rate: 2 chars/frame at small gaps, up to 12 chars/frame when falling behind.
- **Alternatives Considered**: Character-by-character reveal (too granular), Xcode's segment-based blur+slide animation (more sophisticated but harder to implement)
- **Rationale**: Line-by-line reveal creates a natural reading rhythm. Reference-type controller solves the Timer/struct capture bug.

### ADR-030: Slide-Over Drawer for Chat History
- **Context**: Need to add chat history browsing to the narrow AI chat panel.
- **Decision**: Implement a slide-over drawer that replaces the message area temporarily with a session list, with horizontal slide transition.
- **Alternatives Considered**: Popover (too cramped), separate panel (fights for space), dropdown menu (too limited)
- **Rationale**: Keeps single-column layout clean in narrow sidebar. Similar to ChatGPT's mobile app history approach.

### ADR-031: Library Chat VM as Standalone (No Document Required)
- **Context**: Adding a Chat tab to the library detail panel for AI chat without needing an open document.
- **Decision**: Add standalone `init()` to ChatViewModel that sets `parent = nil`. Add lazy `libraryChatVM` to AppState that persists across tab switches.
- **Rationale**: Users need to ask AI questions about their collection without opening specific documents.

---

## UI Architecture & Design

### ADR-032: Chrome-Style Browser Tabs with Concave Arcs
- **Context**: Redesigning document tab bar to look like browser tabs.
- **Decision**: Custom `BrowserTabShape` with rounded top corners and concave inverse arcs at bottom. Selected tab is white (matching content area), negative margin overlapping between adjacent tabs with z-index layering.
- **Rationale**: Chrome/Dia tab pattern where selected tab visually merges with content below is the most polished look.

### ADR-033: SideNav Panel Design (JetBrains IDE Style)
- **Context**: Redesigning the right panel toggle strip.
- **Decision**: Vertical SideNav strip with toggle buttons (AI Chat, Notes, Reference). Clicking toggles panel open/close. Settings gear stays in tab bar row.
- **Rationale**: JetBrains IDE-style side nav with toggle buttons is space-efficient and discoverable.

### ADR-034: Dia Browser Color System Adoption
- **Context**: Improving OakReader's aesthetics by studying Dia Browser's color theme.
- **Decision**: Replace hardcoded hex grays with `Color.primary.opacity(N)` pattern inspired by Dia. Tab bar background #F5F5F5, selected tab white, content white.
- **Rationale**: Dia uses black with varying opacity which auto-adapts to light/dark modes. Feels more refined than flat hex values.

### ADR-035: CodeEdit-Inspired Settings Architecture
- **Context**: Settings used ZStack opacity toggle (both tabs always in memory) and all code in one file.
- **Decision**: Adopt CodeEdit's pattern: `switch` statement on selectedTab for lazy rendering, one file per settings page, `NavigationSplitView` + `List(selection:)` for native sidebar animations.
- **Alternatives Considered**: ZStack opacity toggle (wasteful), manual HStack/VStack/Button (no animation)
- **Rationale**: Native macOS sidebar provides built-in smooth selection animation. Switch-based approach is more memory efficient.

### ADR-036: CodeEdit-Style View Decomposition (`private extension`)
- **Context**: Several large files contained multiple types with 100+ line bodies.
- **Decision**: Adopt CodeEdit's `private extension` pattern for sub-views (body lists composed properties, all sub-views in `private extension`).
- **Rationale**: Keeps body clean, easy to reorder sub-views, cleaner separation of interface and implementation.

### ADR-037: Search Moved from Toolbar to Left Sidebar
- **Context**: Search was a toolbar button with limited space for results.
- **Decision**: Add `search` case to SidebarMode with search field, result count + navigation, and scrollable results list with page numbers and text snippets. Cmd+F switches to search sidebar.
- **Rationale**: Sidebar provides ample vertical space for search results with context snippets. Matches other sidebar modes (Thumbnails, Outline, Annotations).

### ADR-038: Text Selection Popup as Horizontal Toolbar
- **Context**: Redesigning the text selection popup from a vertical list to compact toolbar.
- **Decision**: Horizontal toolbar positioned above the selection with groups: [Highlight|Chevron] [Underline] | [Chat] [Note] | [Copy]. Split-button highlight with dropdown color sub-panel.
- **Rationale**: UPDF/Figma-style horizontal toolbar is more compact. Positioning above selection avoids occluding selected text.

### ADR-039: Fan-Out Attachment Cards (Dia Browser Style)
- **Context**: Chat attachments rendered as flat inline chips.
- **Decision**: Overlapping cards with slight rotation (max +/-3 degrees), hover-to-expand interaction.
- **Rationale**: Visual design inspired by Dia Browser's context cards. Hover-to-expand is more fluid than a click toggle.

### ADR-040: Disable Auto-Highlight on Text Selection Popup Dismiss
- **Context**: Clicking outside the popup automatically highlighted the selection.
- **Decision**: Set `autoHighlightOnDismiss` to `false`. Dismissing simply closes without adding highlight.
- **Rationale**: Clicking away is the universal "never mind" gesture. Auto-highlighting on dismiss forces users to undo unintended annotations.

---

## Infrastructure & Tooling

### ADR-041: Dual Logging System (os.Logger + File Persistence)
- **Context**: ~48 NSLog calls with manual category prefixes, no log levels, no file persistence.
- **Decision**: `Log` enum facade with 7 category loggers using `os.Logger`, plus `LogFileWriter` singleton appending to `~/OakReader/logs/oakreader.log` with 5MB rotation.
- **Alternatives Considered**: Continuing with NSLog (rejected — no levels, privacy, filtering, performance cost)
- **Rationale**: os.Logger provides near-zero cost when not collected, proper log levels, privacy annotations, Console.app integration. File persistence enables user bug reports.

### ADR-042: SwiftLint + SwiftFormat Configuration
- **Context**: No linting or formatting tooling for the growing codebase.
- **Decision**: Add SwiftLint (post-compile, non-blocking with `|| true`) and SwiftFormat (`--maxwidth 120`, `--indent 4`). Disable `todo`, `trailing_comma`, `nesting` rules.
- **Rationale**: Automated code quality enforcement without breaking builds.

### ADR-043: Makefile Over Nx for Monorepo Build Coordination
- **Context**: Whether to use Nx for project management with Swift app + Chrome extension.
- **Decision**: Root `Makefile` with targets: `make all`, `make build`, `make extension`, `make extension-dev`, `make clean`.
- **Alternatives Considered**: Nx (rejected — no Swift/Xcode understanding, adds complexity for one JS package)
- **Rationale**: 95% of the codebase is Swift/Xcode. XcodeGen handles the Swift side. Makefile provides single `make build` without framework overhead.

### ADR-044: Conventional Commits Specification
- **Context**: Standardizing commit message format.
- **Decision**: Adopt Conventional Commits 1.0.0 (`<type>[scope]: <description>`) enforced via custom Claude Code skill.
- **Rationale**: Structured commit messages support automated changelog generation and semantic versioning.

### ADR-045: Accessibility via .help() and TooltipTrigger
- **Context**: Accessibility audit found 24 issues, zero `.accessibilityLabel` modifiers.
- **Decision**: Use `.help()` for VoiceOver on plain-style buttons, and `TooltipTrigger` NSViewRepresentable for deeply nested buttons where `.help()` fails.
- **Alternatives Considered**: `.accessibilityLabel()` (didn't propagate on macOS plain-style buttons)
- **Rationale**: `.help()` sets both tooltip and VoiceOver hint on macOS.

---

## Feature Scoping

### ADR-046: Remove OCR and PDF Editing Features
- **Context**: App positioned as a PDF reader, not editor. Menu items for New Blank PDF, Run OCR, and editing annotations existed.
- **Decision**: Remove OCR service/viewmodel, New Blank PDF, New from Images menu items. Remove sticky note/free text/ink annotation tools. Keep highlight, underline, and area annotations.
- **Rationale**: OakReader is a reader, not an editor. Removing unused features keeps codebase clean and UI focused.

### ADR-047: Extension System — Three-Phase Approach
- **Context**: How to design an extension system, referencing Raycast and CodeEditApp approaches.
- **Decision**: Phase 1: JSON-based AI skills (users drop `.json` files in `~/.oakreader/skills/`). Phase 2: JavaScriptCore plugin runtime. Phase 3: Apple ExtensionKit. Start with Phase 1 only.
- **Alternatives Considered**: Raycast model (React/TS + V8 isolates), CodeEditApp model (ExtensionKit + XPC)
- **Rationale**: Phase 1 covers 90% of value for 10% of effort. No security concerns since it's just prompt text, no code execution. ExtensionKit adoption is low due to poor Apple documentation.

### ADR-048: CrossRef API for Automatic Metadata Extraction
- **Context**: Need automatic metadata population when importing PDFs.
- **Decision**: Extract DOI via regex from first 3 PDF pages, then look up CrossRef API (free, 170M records) for structured metadata.
- **Rationale**: DOI regex extraction from PDF text is the standard approach. CrossRef is the most reliable source since publishers deposit metadata directly.
