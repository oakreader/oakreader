# OakReader

An AI-powered PDF reader for macOS. Ask questions, summarize, extract insights — all from your documents.

## Why OakReader

Most PDF readers just display pages. OakReader understands them. Built-in AI lets you chat with your documents, get instant summaries, and extract the information you need — without switching apps or copy-pasting into a browser.

## AI Features

- **Chat with PDFs** — ask questions about your document and get accurate, context-aware answers
- **Multi-provider support** — works with Claude, OpenAI, and Google Gemini
- **Skill-based workflows** — summarize, translate, explain, extract key points, and more
- **Session management** — keep multiple chat threads per document, revisit past conversations
- **Context-aware** — AI reads the actual PDF content, not just OCR text

## PDF Reader

- High-performance rendering via PDFKit
- Continuous scroll, single page, and two-up layouts
- Thumbnail sidebar, bookmarks, and full-text search
- Multi-window and tabbed document support
- Annotations: highlights, notes, freehand drawing, shapes, stamps
- Page organization: reorder, rotate, delete, insert, split, merge
- OCR for scanned documents (Apple Vision framework)
- Fill & sign forms
- AES-256 encryption and content redaction
- Export to JPEG, PNG, TIFF, RTF, and plain text
- Batch processing for multi-file operations

## Tech Stack

| Component | Framework |
|-----------|-----------|
| UI | SwiftUI + AppKit |
| PDF Engine | PDFKit |
| AI | Claude API, OpenAI API, Google Gemini API |
| OCR | Vision |
| Graphics | CoreGraphics, CoreImage |
| Concurrency | Swift async/await |

## Requirements

- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later

## Build

```bash
git clone https://github.com/nicoji/oakreader.git
cd oakreader
open OakReader.xcodeproj
```

Select the **OakReader** scheme, then build and run (Cmd+R).

Or use XcodeGen:

```bash
brew install xcodegen
xcodegen generate
open OakReader.xcodeproj
```

## License

MIT
