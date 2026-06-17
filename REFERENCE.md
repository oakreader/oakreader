# Reference Projects

External projects, libraries, apps, and codebases referenced during OakReader development, extracted from 52 Claude Code sessions (Apr 22 – May 1, 2026).

---

## Primary Inspirations (Extensively Studied)

### Zotero
- **Type**: App + Codebase (cloned and studied)
- **URL**: https://github.com/zotero/zotero
- **How Used**: Primary architectural inspiration
- **What Was Adopted**:
  - Storage model: `~/Zotero/` directory structure with 8-char random keys → adopted as `~/OakReader/storage/{key}/`
  - SQLite as single source of truth for metadata, filesystem for binaries
  - Web snapshot capture: SingleFile + localhost HTTP server (port 23119)
  - Annotation storage in database, not in files (`itemAnnotations` table pattern)
  - Collections as logical many-to-many groupings, not filesystem folders
  - Non-sandboxed Electron distribution model
  - Right-panel tabbed sidebar (info/notes/tags/related)
  - Metadata inspector underline style for dense field grids
  - Settings UI flat field list layout
- **What Was Studied but Rejected**:
  - EAV schema (36 item types, 123 fields, 5 tables with 3-way JOINs) → replaced with CSL JSON blobs
  - CSL_TYPE_MAPPINGS / CSL_TEXT_MAPPINGS → simplified by storing CSL JSON directly

### Zotero Connector (zotero-connectors)
- **Type**: Codebase
- **URL**: https://github.com/zotero/zotero-connectors
- **How Used**: Studied for Chrome extension architecture
- **What Was Adopted**:
  - SingleFile integration pattern for web snapshot capture
  - Chrome extension → desktop app communication via localhost HTTP server
  - Web snapshot capture flow (inject SingleFile, getPageData, POST to desktop app)
  - `singlefile.fetch` / `singlefile.fetchResponse` message pattern for CORS bypass

### MiaoYan (tw93/MiaoYan)
- **Type**: Codebase (cloned and studied)
- **URL**: https://github.com/tw93/MiaoYan
- **How Used**: Primary reference for note editor implementation
- **What Was Adopted**:
  - NSTextView editor setup (`EditTextView.swift` patterns)
  - Regex-based syntax highlighting (`NotesTextProcessor.swift`)
  - Highlightr integration for code blocks
  - WKWebView preview with CSS/JS bundle (`DownView.bundle` → `Preview.bundle`, stripped from ~6MB to ~468KB)
  - cmark-gfm markdown-to-HTML conversion (`Markdown.swift` → `MarkdownRenderer.swift`)
  - CSS/JS for: highlight.js, KaTeX math, Lightense image zoom, Heti CJK typography
  - Diagram support (Mermaid, PlantUML via JS bundle)
  - TsangerJinKai02-W04 font bundled into OakReader
  - Color scheme inspiration (purple for headings, teal for links)
  - Sidebar collection UI spacing/sizing values

### CodeEdit (CodeEditApp)
- **Type**: Codebase (cloned and studied)
- **URL**: https://github.com/CodeEditApp/CodeEdit
- **How Used**: Code style and architecture patterns reference
- **What Was Adopted**:
  - `private extension` view decomposition pattern
  - Switch-based tab rendering for settings (lazy, only active tab in memory)
  - One file per view convention
  - Consistent MARK sections
  - `@AppSettings` property wrapper pattern concept
  - Feature-based directory structure
  - SwiftLint configuration adapted for OakReader
  - ExtensionKit usage studied for extension system design

### Dia Browser
- **Type**: App (installed locally)
- **How Used**: Design system inspiration
- **What Was Adopted**:
  - Color system: `Color.primary.opacity(N)` instead of hardcoded hex grays
  - Specific gray scale values (Gray2: #F8F8F8 through Gray5: #E7E7E7)
  - Layered black opacity for tints (5%, 20%, 35%, 50%)
  - Fan-out context card design for chat attachments
  - Thin scrollbar style (3pt capsule, auto-fade)
  - Chrome-style tab shape and behavior

---

## Adopted Libraries

### GRDB.swift
- **URL**: https://github.com/groue/GRDB.swift
- **Role**: SQLite wrapper for all library metadata storage
- **Why Chosen**: Type-safe Swift DSL, migrations, database observation for SwiftUI, thread-safe concurrency, FTS5 support. Full schema control needed for ElectricSQL/Postgres compatibility.

### Textual (gonzalezreal)
- **URL**: https://github.com/gonzalezreal/textual
- **Version**: 0.1.0 → 0.3.1
- **Role**: AI chat bubble markdown rendering
- **Why Chosen**: Native SwiftUI StructuredText with CommonMark, LaTeX math (`.math` extension), code highlighting, streaming-friendly incremental updates. Required bumping macOS target to 15.0.

### SingleFile / single-file-core
- **URL**: https://github.com/gildas-lormeau/SingleFile
- **Role**: Self-contained HTML web snapshot capture in Chrome extension
- **Why Chosen**: Inlines all resources (images, CSS, fonts) as base64 data URIs. MIT licensed. Same library Zotero uses.

### Highlightr
- **URL**: https://github.com/raspu/Highlightr
- **Role**: Code syntax highlighting in note editor (NSTextView)
- **Why Chosen**: Wraps highlight.js for NSTextView attributed strings. 190+ languages. Same library MiaoYan uses. `atom-one-light` / `tomorrow-night-blue` themes.

### swift-cmark-gfm (stackotter)
- **URL**: https://github.com/stackotter/swift-cmark-gfm
- **Version**: 1.0.2
- **Role**: GFM markdown-to-HTML conversion for note preview
- **Why Chosen**: Swift wrapper around cmark-gfm C library. Extensions: table, footnotes, strikethrough, tasklist, autolink.

### WXT (Web Extension Tools)
- **Role**: Chrome extension build framework (Manifest V3 + TypeScript)
- **Why Chosen**: HMR dev mode, TypeScript type safety, Vite-based bundling. Handles `web_accessible_resources`, content script registration.

### XcodeGen
- **Role**: Generate `.xcodeproj` from `project.yml`
- **Why Chosen**: Already adopted. New files auto-included under source paths.

### Conventional Commits
- **URL**: https://www.conventionalcommits.org/
- **Role**: Commit message specification
- **Why Chosen**: Structured format (`<type>[scope]: <description>`) for automated changelog and semantic versioning.

---

## Bundled Libraries (via MiaoYan Preview.bundle)

### highlight.js
- **Role**: Code syntax highlighting in WKWebView note preview

### KaTeX (Khan Academy)
- **Role**: LaTeX math rendering in note preview
- **Notes**: ~10-100x faster than MathJax, 280KB vs 1.5MB bundle

### Lightense
- **Role**: Click-to-zoom for images in note preview

### Heti
- **Role**: CJK typography CSS (951 lines) for Chinese/Japanese/Korean text rendering

### Mermaid.js
- **Role**: Flowchart/sequence diagram rendering (bundled from MiaoYan, includes ELK layout engine)

### PlantUML
- **URL**: https://www.plantuml.com/plantuml/svg/
- **Role**: UML diagram rendering (server-side, requires network)

---

## Evaluated but Rejected

### MarkdownEditor (Pallepadehat)
- **URL**: https://github.com/Pallepadehat/MarkdownEditor
- **Type**: CodeMirror 6 in WKWebView
- **Verdict**: Initially adopted, then replaced. Persistent bugs: code block detection failures, horizontal overflow, backtick input interference.

### MarkdownView (LiYanan2004)
- **URL**: https://github.com/LiYanan2004/MarkdownView
- **Type**: SwiftUI markdown renderer
- **Verdict**: Rejected — re-parses full markdown AST on every content change, causing high CPU and main thread blocking during streaming.

### MarkEdit (MarkEdit-app)
- **URL**: https://github.com/MarkEdit-app/MarkEdit
- **Type**: macOS markdown editor (CodeMirror 6)
- **Verdict**: Rejected — pure text editor, no inline preview, no math rendering, no syntax hiding. Would be a downgrade.

### MarkupEditor (stevengharris)
- **URL**: https://github.com/stevengharris/MarkupEditor
- **Type**: ProseMirror-based WYSIWYG editor
- **Verdict**: Rejected — no math support (no KaTeX), content format is HTML not markdown.

### SwiftDown (qeude)
- **URL**: https://github.com/qeude/SwiftDown
- **Type**: Native NSTextView markdown editor
- **Verdict**: Rejected — too simple: no math, no image rendering, not WYSIWYG.

### RaTeX (erweixin)
- **URL**: https://github.com/erweixin/RaTeX
- **Type**: Rust-based KaTeX with SwiftUI
- **Verdict**: Rejected — LaTeX math only, no general markdown rendering.

### MathJax
- **Type**: LaTeX renderer
- **Verdict**: Rejected in favor of KaTeX — significantly slower and larger (~99% vs ~95% coverage, but noticeable delay during streaming).

### Nx Build System
- **Type**: Monorepo manager
- **Verdict**: Rejected — no understanding of xcodebuild/XcodeGen/Swift, unnecessary for one JS package.

---

## Design References (UX/UI Inspiration)

### Apple Notes
- **What Was Referenced**: Note list design (grouped by month, bold title, date, pin indicator), font sizing defaults (17px)

### Obsidian
- **What Was Referenced**: Syntax-hiding editing model, `[[]]` bidirectional linking syntax, `/` slash command menu, non-sandboxed distribution model

### Notion
- **What Was Referenced**: `/` slash command menu design, EAV property system (studied but rejected for OakReader's scope)

### Bear.app
- **What Was Referenced**: CSS styling for markdown editor (clean sans-serif typography, code block styling, progressive heading sizes)

### UPDF
- **What Was Referenced**: Text selection horizontal toolbar design, split-button highlight with color dropdown

### Figma
- **What Was Referenced**: Compact horizontal toolbar style for text selection popup

### ChatGPT Mobile App
- **What Was Referenced**: Slide-over chat history drawer design

### JetBrains IDE
- **What Was Referenced**: Side tool window bar with toggle buttons for panel open/close

### Chrome Browser
- **What Was Referenced**: Tab shape (selected = white merging with content, concave arcs, negative margin overlapping)

### Xcode (IDEIntelligenceChat.framework)
- **What Was Referenced**: AI chat font settings (`.body` / SF Pro 13pt), streaming animation approach (`AnimatableStreamingTextViewModel`)

### mymind
- **What Was Referenced**: Inbox + extension quick-save flow (save now, organize later)

### Amazon Kindle Screensaver
- **What Was Referenced**: Classic boy-under-tree image as initial logo design inspiration → evolved to oak leaf concept

### Sarea (user's own app)
- **What Was Referenced**: Settings page NavigationSplitView + List(selection:) for smooth tab switching, compared against OakReader's manual implementation

---

## Studied for Research (Not Directly Applied)

### ElectricSQL
- **URL**: https://electric-sql.com/
- **Role**: Planned future sync layer (SQLite ↔ PostgreSQL)
- **Status**: Schema designed for compatibility, implementation deferred

### Library Genesis (libgen)
- **URL**: libgen.li, libgen.rs
- **What Was Studied**: Search API (HTML endpoint, JSON API), DNS-level blocking workarounds

### CrossRef API
- **URL**: https://api.crossref.org/
- **Role**: Adopted for automatic DOI-based metadata extraction (170M+ records)

### CSL (Citation Style Language)
- **URL**: https://citeproc-js.readthedocs.io/en/latest/csl-json/markup.html
- **Role**: Adopted as canonical data format for bibliographic metadata (43 item types, 80+ variables)

### C2PA / Content Credentials
- **What Was Studied**: AI image watermarking standard (used by DALL-E, Adobe Firefly). Informational only.

### SynthID (Google)
- **What Was Studied**: Pixel-level invisible watermark surviving screenshots/cropping. Informational only.

### Ranganathan's Colon Classification
- **What Was Studied**: 1930s origin of faceted classification in library science. Context for tag group design discussion.

---

## Competitive Analysis

| App | Relationship |
|-----|-------------|
| PDF Expert | Cloud sync as paid feature (validated OakReader's commercial strategy) |
| MarginNote | Cloud sync as paid feature |
| Mendeley | Logical collections model, reference management comparison |
| Papers | Went web-based (validated native macOS gap) |
| Bookends | Closest competitor but dated |
| DEVONthink | Non-sandboxed distribution model |
| Calibre | Non-sandboxed distribution model |
| Airtable | EAV property system (studied, rejected for OakReader's scope) |

**Key competitive insight**: "No existing tool combines a first-class native macOS PDF reader with reference management. Bookends is closest but dated. Papers went web-based."

---

## Extension System Research

### Raycast Extensions
- **URL**: github.com/raycast/extensions
- **What Was Studied**: React/TS + V8 isolates, custom reconciler (React → JSON → native AppKit), centralized GitHub monorepo distribution, mandatory open-source + code review sandboxing

### Chime / ChimeKit / Extendable
- **URL**: https://github.com/ChimeHQ/Chime, /ChimeKit, /Extendable
- **What Was Studied**: Best real-world open-source example of Apple ExtensionKit usage. ChimeKit is the extension SDK; Extendable provides SwiftUI utilities.

### TextTransformer (Guilherme Rambo)
- **URL**: https://github.com/insidegui/TextTransformer
- **What Was Studied**: Demo app demonstrating custom extension points with ExtensionFoundation/ExtensionKit. Blog: https://www.rambo.codes/posts/2022-06-27-creating-custom-extension-points-with-extensionkit
