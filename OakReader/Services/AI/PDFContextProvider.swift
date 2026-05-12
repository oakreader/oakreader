import Foundation
import PDFKit
import AppKit
import OakAgent

/// Snapshot of document context to pass across actor boundaries.
public struct PDFContextSnapshot: Sendable {
    public let fileName: String
    public let pageCount: Int
    public let currentPageIndex: Int
    public let currentPageText: String
    public let fullDocumentText: String?   // nil if not needed by skill
    public let selectedText: String?

    public init(
        fileName: String,
        pageCount: Int,
        currentPageIndex: Int,
        currentPageText: String,
        fullDocumentText: String? = nil,
        selectedText: String? = nil
    ) {
        self.fileName = fileName
        self.pageCount = pageCount
        self.currentPageIndex = currentPageIndex
        self.currentPageText = currentPageText
        self.fullDocumentText = fullDocumentText
        self.selectedText = selectedText
    }
}

/// Creates a Sendable PDFContextSnapshot from the current document state.
struct PDFContextProvider {
    private let textExtractor = TextExtractionService()

    func snapshot(
        from viewModel: DocumentViewModel,
        contextMode: ContextMode
    ) -> PDFContextSnapshot? {
        switch viewModel.itemType {
        case .pdf:
            return pdfSnapshot(from: viewModel, contextMode: contextMode)
        case .webSnapshot:
            return webSnapshotSnapshot(from: viewModel, contextMode: contextMode)
        case .embed:
            return mediaSnapshot(from: viewModel, contextMode: contextMode)
        case .markdown:
            return markdownSnapshot(from: viewModel, contextMode: contextMode)
        }
    }

    /// Build a system prompt from a skill and document context.
    ///
    /// This is the app-layer prompt builder that was formerly inside ChatEngine.
    /// The caller passes the result to ``AgentSession/send(…systemPrompt:…)``.
    static func buildSystemPrompt(skill: Skill?, context: PDFContextSnapshot?) -> String {
        var parts: [String] = []

        // Base system prompt
        parts.append("""
            You are a helpful AI assistant integrated into OakReader, \
            a document reader application. Do not praise questions or \
            validate premises — if the user is wrong, say so directly. \
            If uncertain, say so; do not fabricate citations or facts. \
            Do not change your answer under pressure unless new evidence \
            is presented.
            """)

        // Skill prompt
        if let skill {
            parts.append(skill.systemPrompt)
        }

        // PDF context
        if let ctx = context {
            parts.append("The user has a PDF document open: \"\(ctx.fileName)\" (\(ctx.pageCount) pages).")
            parts.append("Current page: \(ctx.currentPageIndex + 1) of \(ctx.pageCount).")

            if let selected = ctx.selectedText, !selected.isEmpty {
                parts.append("Selected text:\n\"\"\"\n\(selected)\n\"\"\"")
            }

            // Determine context based on skill
            let contextMode = skill?.contextMode ?? .currentPage
            switch contextMode {
            case .fullDocument:
                if let fullText = ctx.fullDocumentText, !fullText.isEmpty {
                    let truncated = String(fullText.prefix(32000))
                    parts.append("Document text:\n\"\"\"\n\(truncated)\n\"\"\"")
                }
            case .currentPage:
                if !ctx.currentPageText.isEmpty {
                    parts.append("Current page text:\n\"\"\"\n\(ctx.currentPageText)\n\"\"\"")
                }
            case .selectedText:
                break // Already handled above
            case .none:
                break
            }
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - Context Snapshot (enriched)

    /// Build a ``ChatContextSnapshot`` capturing all app + document context for the AI.
    static func buildContextSnapshot(
        from documentVM: DocumentViewModel?,
        appState: AppState?,
        contextMode: ContextMode
    ) -> ChatContextSnapshot {
        // App-level context
        let collection = appState?.libraryStore.selectedCollection
        let collectionName = collection?.name
        let collectionItemCount = collection?.itemCount

        let openTabTitles = appState?.openTabs.map(\.title) ?? []
        let activeTabTitle = appState?.activeTab?.title

        // Document context
        let docContext: ChatContextSnapshot.DocumentContext?
        if let vm = documentVM {
            docContext = buildDocumentContext(from: vm, contextMode: contextMode)
        } else {
            docContext = nil
        }

        return ChatContextSnapshot(
            activeCollectionName: collectionName,
            activeCollectionItemCount: collectionItemCount,
            openTabTitles: openTabTitles,
            activeTabTitle: activeTabTitle,
            document: docContext
        )
    }

    private static func buildDocumentContext(
        from vm: DocumentViewModel,
        contextMode: ContextMode
    ) -> ChatContextSnapshot.DocumentContext {
        let provider = PDFContextProvider()

        // Extract current page text
        let currentPageText: String
        let currentPageIndex = vm.state.currentPageIndex
        let pageCount = vm.pageCount

        switch vm.itemType {
        case .pdf:
            if let pdfDoc = vm.pdfDocument, let page = pdfDoc.page(at: currentPageIndex) {
                currentPageText = provider.textExtractor.extractText(from: page)
            } else {
                currentPageText = ""
            }
        case .webSnapshot:
            if let snapshot = vm.webSnapshot {
                // Prefer markdown saved by browser extension alongside the HTML
                let mdURL = snapshot.htmlURL.deletingLastPathComponent()
                    .appendingPathComponent("content.md")
                if let md = try? String(contentsOf: mdURL, encoding: .utf8), !md.isEmpty {
                    currentPageText = String(md.prefix(4_000))
                } else {
                    currentPageText = String(
                        provider.extractTextFromHTML(url: snapshot.htmlURL).prefix(4_000)
                    )
                }
            } else {
                currentPageText = ""
            }
        case .embed:
            if let media = vm.mediaDocument {
                if let url = media.transcriptURL,
                   let text = try? String(contentsOf: url, encoding: .utf8) {
                    currentPageText = String(text.prefix(4_000))
                } else {
                    currentPageText = media.metadata.description ?? ""
                }
            } else {
                currentPageText = ""
            }
        case .markdown:
            if let mdDoc = vm.markdownDocument {
                currentPageText = String(mdDoc.content.prefix(4_000))
            } else {
                currentPageText = ""
            }
        }

        // Library metadata
        let item = vm.libraryItem
        let title = item?.title ?? vm.fileName
        let author = item?.author ?? ""
        let citeKey = item?.citeKey
        let sourceURL = item?.sourceURL?.absoluteString
        let filePath = item?.fileURL.path ?? ""

        // Tags from property values
        let tags: [String] = item?.propertyValues
            .filter { $0.propertyName == "Tags" }
            .compactMap { $0.option?.name } ?? []

        // Collection names
        let collectionNames: [String] = item?.collections.map(\.name) ?? []

        // Reference metadata
        let ref = item?.referenceMetadata
        let csl = ref?.cslItem

        // Notes
        var noteSummaries: [(id: UUID, title: String)] = []
        if let db = vm.database, let storageKey = vm.itemStorageKey {
            let noteService = NoteService(database: db)
            if let notes = try? noteService.fetchNotes(forItemId: storageKey) {
                noteSummaries = notes.map { ($0.id, $0.displayTitle) }
            }
        }

        return ChatContextSnapshot.DocumentContext(
            fileName: vm.fileName,
            filePath: filePath,
            itemType: vm.itemType.rawValue,
            pageCount: pageCount,
            currentPageIndex: currentPageIndex,
            currentPageText: currentPageText,
            selectedText: vm.state.selectedText,
            title: title,
            author: author,
            citeKey: citeKey,
            sourceURL: sourceURL,
            tags: tags,
            collectionNames: collectionNames,
            referenceType: csl?.type,
            doi: csl?.DOI,
            journal: csl?.containerTitle,
            year: ref?.year,
            abstract: csl?.abstract,
            volume: csl?.volume,
            issue: csl?.issue,
            pages: csl?.page,
            noteCount: noteSummaries.count,
            noteSummaries: noteSummaries
        )
    }

    // MARK: - System Prompt (enriched)

    /// Build a system prompt from a skill and enriched context snapshot.
    /// Uses structured XML for metadata, includes current page text, and references
    /// available tools for on-demand document reading.
    static func buildSystemPrompt(skill: Skill?, context: ChatContextSnapshot) -> String {
        var parts: [String] = []

        // Base system prompt
        parts.append("""
            You are a helpful AI assistant integrated into OakReader, \
            a document reader application. Do not praise questions or \
            validate premises — if the user is wrong, say so directly. \
            If uncertain, say so; do not fabricate citations or facts. \
            Do not change your answer under pressure unless new evidence \
            is presented.
            """)

        // App context
        var appContextParts: [String] = []
        if let name = context.activeCollectionName {
            let countAttr = context.activeCollectionItemCount.map { " items=\"\($0)\"" } ?? ""
            appContextParts.append("  <active-collection name=\"\(xmlEscape(name))\"\(countAttr) />")
        }
        if !context.openTabTitles.isEmpty {
            var tabLines: [String] = []
            for title in context.openTabTitles {
                let activeAttr = title == context.activeTabTitle ? " active=\"true\"" : ""
                tabLines.append("    <tab title=\"\(xmlEscape(title))\"\(activeAttr) />")
            }
            appContextParts.append("  <open-tabs>\n\(tabLines.joined(separator: "\n"))\n  </open-tabs>")
        }
        if !appContextParts.isEmpty {
            parts.append("<app-context>\n\(appContextParts.joined(separator: "\n"))\n</app-context>")
        }

        // Document context
        if let doc = context.document {
            var docParts: [String] = []

            // File info
            docParts.append("  <file name=\"\(xmlEscape(doc.fileName))\" path=\"\(xmlEscape(doc.filePath))\" />")

            // Metadata
            var metaAttrs = "title=\"\(xmlEscape(doc.title))\""
            if !doc.author.isEmpty { metaAttrs += " author=\"\(xmlEscape(doc.author))\"" }
            if let ck = doc.citeKey { metaAttrs += " cite-key=\"\(xmlEscape(ck))\"" }
            if let url = doc.sourceURL { metaAttrs += " source-url=\"\(xmlEscape(url))\"" }
            docParts.append("  <metadata \(metaAttrs) />")

            // Reference metadata (only if present)
            if let refType = doc.referenceType {
                var refAttrs = "type=\"\(xmlEscape(refType))\""
                if let doi = doc.doi { refAttrs += " doi=\"\(xmlEscape(doi))\"" }
                if let journal = doc.journal { refAttrs += " journal=\"\(xmlEscape(journal))\"" }
                if let year = doc.year { refAttrs += " year=\"\(year)\"" }
                if let vol = doc.volume { refAttrs += " volume=\"\(xmlEscape(vol))\"" }
                if let iss = doc.issue { refAttrs += " issue=\"\(xmlEscape(iss))\"" }
                if let pages = doc.pages { refAttrs += " pages=\"\(xmlEscape(pages))\"" }
                docParts.append("  <reference \(refAttrs) />")
            }

            // Tags
            if !doc.tags.isEmpty {
                docParts.append("  <tags>\(doc.tags.joined(separator: ", "))</tags>")
            }

            // Collections
            if !doc.collectionNames.isEmpty {
                docParts.append("  <collections>\(doc.collectionNames.joined(separator: ", "))</collections>")
            }

            // Notes summary
            if doc.noteCount > 0 {
                let titles = doc.noteSummaries.map(\.title).joined(separator: "; ")
                docParts.append("  <notes count=\"\(doc.noteCount)\">\(xmlEscape(titles))</notes>")
            }

            // Selected text
            if let selected = doc.selectedText, !selected.isEmpty {
                docParts.append("  <selected-text>\n\(selected)\n  </selected-text>")
            }

            // Current page text (always include — immediately relevant)
            if !doc.currentPageText.isEmpty {
                let truncated = String(doc.currentPageText.prefix(4_000))
                docParts.append("  <current-page index=\"\(doc.currentPageIndex + 1)\">\n\(truncated)\n  </current-page>")
            }

            let docBlock = docParts.joined(separator: "\n")
            parts.append(
                "<document type=\"\(xmlEscape(doc.itemType))\" pages=\"\(doc.pageCount)\">\n\(docBlock)\n</document>"
            )

            // Tool usage hint
            parts.append("""
                You have tools to read document pages (read_document), search within the \
                document (search_document), read notes (read_notes), and find conceptually \
                related items via vector search (search_semantic). Use search_semantic for \
                thematic queries and search_library for keyword matches.
                """)

            // Abstract (outside document block to not crowd metadata)
            if let abstract = doc.abstract, !abstract.isEmpty {
                parts.append("Document abstract:\n\"\"\"\n\(String(abstract.prefix(2_000)))\n\"\"\"")
            }
        }

        // Skill prompt (after context so the skill can reference it)
        if let skill {
            parts.append(skill.systemPrompt)
        }

        return parts.joined(separator: "\n\n")
    }

    /// Escape special XML characters in attribute values and text content.
    private static func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - PDF

    private func pdfSnapshot(
        from viewModel: DocumentViewModel,
        contextMode: ContextMode
    ) -> PDFContextSnapshot? {
        guard let pdfDoc = viewModel.pdfDocument else { return nil }

        let currentPageIndex = viewModel.state.currentPageIndex
        let currentPageText: String
        if let page = pdfDoc.page(at: currentPageIndex) {
            currentPageText = textExtractor.extractText(from: page)
        } else {
            currentPageText = ""
        }

        var fullText: String?
        if contextMode == .fullDocument {
            let raw = textExtractor.extractAllText(from: pdfDoc)
            // Truncate to ~32K characters (~8K tokens)
            fullText = String(raw.prefix(32_000))
        }

        return PDFContextSnapshot(
            fileName: viewModel.fileName,
            pageCount: viewModel.pageCount,
            currentPageIndex: currentPageIndex,
            currentPageText: currentPageText,
            fullDocumentText: fullText,
            selectedText: viewModel.state.selectedText
        )
    }

    // MARK: - Web Snapshot

    private func webSnapshotSnapshot(
        from viewModel: DocumentViewModel,
        contextMode: ContextMode
    ) -> PDFContextSnapshot? {
        guard let snapshot = viewModel.webSnapshot else { return nil }

        let htmlText = extractTextFromHTML(url: snapshot.htmlURL)
        let truncated = String(htmlText.prefix(32_000))

        return PDFContextSnapshot(
            fileName: viewModel.fileName,
            pageCount: 1,
            currentPageIndex: 0,
            currentPageText: truncated,
            fullDocumentText: contextMode == .fullDocument ? truncated : nil,
            selectedText: viewModel.state.selectedText
        )
    }

    // MARK: - Media (Embed)

    private func mediaSnapshot(
        from viewModel: DocumentViewModel,
        contextMode: ContextMode
    ) -> PDFContextSnapshot? {
        guard let media = viewModel.mediaDocument else { return nil }

        // Read transcript, fall back to description
        var text = ""
        if let transcriptURL = media.transcriptURL,
           let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            text = transcript
        } else if let description = media.metadata.description {
            text = description
        }
        let truncated = String(text.prefix(32_000))

        return PDFContextSnapshot(
            fileName: media.metadata.title,
            pageCount: 1,
            currentPageIndex: 0,
            currentPageText: truncated,
            fullDocumentText: contextMode == .fullDocument ? truncated : nil,
            selectedText: viewModel.state.selectedText
        )
    }

    // MARK: - Markdown

    private func markdownSnapshot(
        from viewModel: DocumentViewModel,
        contextMode: ContextMode
    ) -> PDFContextSnapshot? {
        guard let mdDoc = viewModel.markdownDocument else { return nil }
        let truncated = String(mdDoc.content.prefix(32_000))

        return PDFContextSnapshot(
            fileName: viewModel.fileName,
            pageCount: 1,
            currentPageIndex: 0,
            currentPageText: truncated,
            fullDocumentText: contextMode == .fullDocument ? truncated : nil,
            selectedText: viewModel.state.selectedText
        )
    }

    /// Extract plain text from an HTML file by stripping tags via NSAttributedString.
    func extractTextFromHTML(url: URL) -> String {
        guard let htmlData = try? Data(contentsOf: url) else { return "" }
        guard let attrString = NSAttributedString(
            html: htmlData,
            baseURL: url.deletingLastPathComponent(),
            documentAttributes: nil
        ) else { return "" }
        return attrString.string
    }
}
