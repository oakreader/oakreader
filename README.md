# OakReader — Native macOS PDF Editor

A full-featured, native macOS PDF editor built entirely with Apple frameworks. OakReader replicates the core functionality of Adobe Acrobat Pro — viewing, editing, annotating, organizing, signing, securing, and converting PDF documents — with zero third-party dependencies.

## Features

### View & Navigate
- High-performance PDF rendering via PDFKit
- Continuous scrolling, single page, and two-up display modes
- Zoom controls with fit-to-page and fit-to-width
- Thumbnail sidebar with drag-to-reorder
- Bookmark/outline tree navigation
- Full-text search with result highlighting and navigation
- Multi-window and tabbed document support

### Edit PDFs
- Inline text editing using the industry-standard redact-and-overlay approach
- Add new text anywhere on a page
- Insert, resize, replace, and crop images
- Content insertion via drag-and-drop

### Annotate & Comment
- Highlight, underline, and strikethrough text
- Sticky notes with customizable colors
- Free text annotations with font, size, and color controls
- Freehand drawing (ink annotations)
- Shapes: lines, arrows, rectangles, ovals
- Stamps: Approved, Draft, Confidential, and custom stamps
- Annotation property inspector (color, opacity, line width, font)
- Annotation list sidebar with click-to-navigate

### Organize Pages
- Drag-and-drop page reordering
- Rotate pages (90/180/270 degrees)
- Delete single or multiple selected pages
- Insert blank pages or pages from other documents
- Extract page ranges to new documents
- Split documents at a page number, into equal parts, or by custom ranges
- Merge multiple PDFs into one with bookmark preservation

### OCR (Optical Character Recognition)
- Vision framework-powered text recognition at 300 DPI
- Makes scanned documents fully searchable
- Processes pages concurrently with progress tracking
- Multi-language support

### Fill & Sign
- Fill interactive form fields (text, checkboxes, dropdowns)
- Create signatures by drawing, typing, or importing images
- Place and resize signatures anywhere on a page
- Persistent signature storage for reuse
- Visual certificate-based signatures with Keychain integration

### Create Fillable Forms
- Add text fields, checkboxes, radio buttons, dropdowns, and signature fields
- Auto-detect form fields on scanned documents using Vision framework
- Configure field properties: name, tooltip, default value, required flag
- Font and size customization per field

### Security & Protection
- AES-256 and AES-128 password encryption
- Separate open and permissions passwords
- Granular permissions: printing, copying, editing, annotations
- Content redaction that **rasterizes pages** — truly destroys underlying content (not cosmetic overlay)
- Post-redaction verification confirms no text is extractable

### Compare Documents
- Side-by-side document comparison
- Text-level diff using LCS algorithm
- Pixel-level visual diff using Core Image
- Color-coded difference highlighting with navigation
- Summary statistics (added, removed, changed)

### Compress
- Reduce file size by downsampling embedded images
- Configurable quality levels: Low, Medium, High, Maximum
- Optional metadata stripping
- Before/after size comparison

### Watermarks
- Text and image watermarks
- Configurable position (center, corners, edges), rotation, opacity, and scale
- Font, size, and color controls for text watermarks
- Apply to all pages or custom page ranges
- Live preview before applying

### Headers, Footers & Bates Numbering
- Six text positions: header left/center/right, footer left/center/right
- Template variables: `<<page>>`, `<<total>>`, `<<date>>`, `<<bates>>`
- Bates numbering with configurable prefix, suffix, start number, and digit count
- Font, size, color, and margin controls
- Live preview

### Accessibility
- PDF structure tag editor (headings, paragraphs, lists, tables, figures)
- Reading order visualization and editing
- Accessibility checker verifying: document title, language, bookmarks, text content, alt text, form labels, link descriptions, structure tags
- Issue severity levels with fix suggestions

### Batch Processing
- Process multiple PDF files at once
- 10 operation types: OCR, compress, watermark, headers/footers, convert to images, merge, password protect, remove password, redact pattern, flatten annotations
- Per-file progress tracking
- Error reporting per file

### Convert & Export
- Export pages as JPEG, PNG, or TIFF at configurable DPI
- Export document text as RTF or plain text
- Import images to create new PDF documents
- Create blank PDFs

### Print
- Native macOS print dialog integration
- Page range printing
- Scale-to-fit and auto-rotate options

## Architecture

```
SwiftUI Views  <-->  ViewModels (@Observable)  <-->  Services (stateless)  <-->  Apple Frameworks
                            |
                      OakReaderDocument
                       (NSDocument)
                            |
                   PDFView (AppKit via NSViewRepresentable)
```

**Pattern:** MVVM with a stateless Service layer

- **OakReaderDocument** (NSDocument subclass) — owns the PDFDocument, handles file I/O, undo/redo, dirty-tracking
- **DocumentViewModel** — root ViewModel owning 15 child ViewModels, one per feature area
- **PDFView** — Apple's AppKit PDF renderer, wrapped via NSViewRepresentable
- **Services** — stateless structs/actors encapsulating Apple framework calls (OCR, compression, comparison, etc.)
- **Models** — value types mirroring PDF state for SwiftUI binding

## Project Structure

```
OakReader/
├── App/                    # App entry point, delegate, Info.plist
├── Document/               # NSDocument subclass, state, document controller
├── Models/                 # 12 data models (pages, annotations, forms, security, etc.)
├── ViewModels/             # 16 observable ViewModels
├── Views/                  # 56 SwiftUI views across 16 subdirectories
│   ├── MainWindow/         #   Root layout, toolbar, status bar
│   ├── Sidebar/            #   Thumbnails, bookmarks, annotations, search
│   ├── Viewer/             #   PDFView wrapper and coordinator
│   ├── Editor/             #   Text and image editing overlays
│   ├── Annotations/        #   Annotation tools and properties
│   ├── Forms/              #   Form field creation and filling
│   ├── Signing/            #   Signature creation and placement
│   ├── Organize/           #   Page grid, merge, split, extract
│   ├── Security/           #   Passwords, permissions, redaction
│   ├── Compare/            #   Side-by-side document comparison
│   ├── Convert/            #   Export and import dialogs
│   ├── Batch/              #   Multi-file batch processing
│   ├── Watermark/          #   Watermark configuration and preview
│   ├── HeaderFooter/       #   Header/footer/Bates configuration
│   ├── Accessibility/      #   Tag editor, reading order, checker
│   └── Shared/             #   Reusable components (color picker, font picker, etc.)
├── Services/               # 18 stateless service files
├── Coordinators/           # Undo, clipboard, drag-drop coordination
├── Extensions/             # 7 framework extensions (PDFKit, CoreGraphics, etc.)
├── Utilities/              # Constants, error types, preferences, file coordination
└── Resources/              # Asset catalog, stamps
```

**121 Swift source files | 18,500+ lines of code**

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later

## Building

1. Clone the repository:
   ```bash
   git clone https://github.com/orico1000/PDF-editor.git
   cd PDF-editor
   ```

2. Open in Xcode:
   ```bash
   open OakReader.xcodeproj
   ```

3. Select the **OakReader** scheme and build (Cmd+B)

4. Run (Cmd+R) — the app opens and can immediately open any PDF file

Alternatively, regenerate the Xcode project from the spec:
```bash
brew install xcodegen
xcodegen generate
open OakReader.xcodeproj
```

## Technology Stack

| Component | Framework |
|-----------|-----------|
| UI | SwiftUI + AppKit |
| PDF Engine | PDFKit |
| OCR | Vision |
| Graphics | CoreGraphics, CoreImage, CoreText |
| Signatures | Security.framework (Keychain) |
| File Types | UniformTypeIdentifiers |
| Concurrency | Swift Concurrency (async/await, TaskGroup) |

**Zero third-party dependencies** — built entirely on Apple's native frameworks.

## Security

A comprehensive security audit was performed covering all 121 source files. Key security measures:

- **Redaction** rasterizes affected pages at 300 DPI, destroying the original content stream. A verification step confirms no text remains extractable from redacted regions.
- **Encryption** uses AES-256 by default (RC4 intentionally excluded as cryptographically broken).
- **URL validation** restricts PDF link schemes to `http`, `https`, and `mailto` to prevent protocol handler abuse.
- **Input safety** — all force-unwraps on untrusted PDF input replaced with safe optional binding.
- **Temp file cleanup** uses `defer` blocks to guarantee removal even on error paths.
- **Sudden termination** disabled to prevent sensitive temp file leakage.

> **Note:** Digital signatures are visual annotations only — they do not implement cryptographic PKCS#7/CMS signing. This is clearly indicated in the UI and code.

## License

All rights reserved. This project is provided as-is for educational and reference purposes.

xcodebuild -project OakReader.xcodeproj -scheme OakReader -configuration Debug build