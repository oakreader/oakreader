import Foundation
import PDFKit
import OakAgent

/// Builds context snapshots and system prompts for the AI chat session.
struct PDFContextProvider {

    // MARK: - Context Snapshot

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

        // Collect items in the active collection (up to 50 for prompt size)
        let collectionItems: [ChatContextSnapshot.CollectionItemSummary]
        if collection != nil, let store = appState?.libraryStore {
            collectionItems = store.filteredItems.prefix(50).map {
                ChatContextSnapshot.CollectionItemSummary(
                    title: $0.title,
                    author: $0.author,
                    citeKey: $0.citeKey
                )
            }
        } else {
            collectionItems = []
        }

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
            activeCollectionItems: collectionItems,
            openTabTitles: openTabTitles,
            activeTabTitle: activeTabTitle,
            document: docContext
        )
    }

    private static func buildDocumentContext(
        from vm: DocumentViewModel,
        contextMode: ContextMode
    ) -> ChatContextSnapshot.DocumentContext {
        let textExtractor = TextExtractionService()

        // Extract current page text
        let currentPageText: String
        let currentPageIndex = vm.state.currentPageIndex
        let pageCount = vm.pageCount

        switch vm.contentType {
        case .pdf:
            if let pdfDoc = vm.pdfDocument, let page = pdfDoc.page(at: currentPageIndex) {
                currentPageText = textExtractor.extractText(from: page)
            } else {
                currentPageText = ""
            }
        case .html:
            if let snapshot = vm.webSnapshot {
                // Prefer markdown saved by browser extension alongside the HTML
                let mdURL = snapshot.htmlURL.deletingLastPathComponent()
                    .appendingPathComponent("content.md")
                if let md = try? String(contentsOf: mdURL, encoding: .utf8), !md.isEmpty {
                    currentPageText = String(md.prefix(4_000))
                } else if let data = try? Data(contentsOf: snapshot.htmlURL) {
                    currentPageText = String(
                        HTMLTextExtractor.extractText(from: data).prefix(4_000)
                    )
                } else {
                    currentPageText = ""
                }
            } else {
                currentPageText = ""
            }
        case .video:
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
        case .audio:
            currentPageText = ""
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

        // Notes — resolve to absolute paths so the AI can use ReadTool
        var notes: [(title: String, path: String)] = []
        if let db = vm.database, let storageKey = vm.itemStorageKey {
            let noteService = NoteService(database: db)
            if let fetched = try? noteService.fetchNotes(forItemId: storageKey) {
                notes = fetched.map {
                    ($0.displayTitle, CatalogDatabase.noteFileURL(noteId: $0.id).path)
                }
            }
        }

        return ChatContextSnapshot.DocumentContext(
            fileName: vm.fileName,
            filePath: filePath,
            contentType: vm.contentType,
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
            notes: notes
        )
    }

    // MARK: - System Prompt

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
            if context.activeCollectionItems.isEmpty {
                appContextParts.append("  <active-collection name=\"\(xmlEscape(name))\"\(countAttr) />")
            } else {
                var lines: [String] = []
                lines.append("  <active-collection name=\"\(xmlEscape(name))\"\(countAttr)>")
                for item in context.activeCollectionItems {
                    var attrs = "title=\"\(xmlEscape(item.title))\""
                    if !item.author.isEmpty { attrs += " author=\"\(xmlEscape(item.author))\"" }
                    if let ck = item.citeKey { attrs += " cite-key=\"\(xmlEscape(ck))\"" }
                    lines.append("    <item \(attrs) />")
                }
                lines.append("  </active-collection>")
                appContextParts.append(lines.joined(separator: "\n"))
            }
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

            // Notes with paths — AI can use ReadTool to read them
            if !doc.notes.isEmpty {
                var noteLines: [String] = []
                for note in doc.notes {
                    noteLines.append(
                        "    <note title=\"\(xmlEscape(note.title))\" path=\"\(xmlEscape(note.path))\" />"
                    )
                }
                docParts.append("  <notes count=\"\(doc.notes.count)\">\n\(noteLines.joined(separator: "\n"))\n  </notes>")
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
                "<document type=\"\(xmlEscape(doc.contentType.rawValue))\" pages=\"\(doc.pageCount)\">\n\(docBlock)\n</document>"
            )

            // Tool usage hint
            parts.append("""
                You have tools to read document pages (read_document), search within the \
                document (search_document), and find conceptually related items via vector \
                search (search_semantic). Use the read tool to read note files by their \
                path listed above. Use search_semantic for thematic queries and \
                search_library for keyword matches.
                """)

            // Abstract (outside document block to not crowd metadata)
            if let abstract = doc.abstract, !abstract.isEmpty {
                parts.append("Document abstract:\n\"\"\"\n\(String(abstract.prefix(2_000)))\n\"\"\"")
            }
        }

        // Citation link format — document-type-aware, unified under oak://cite/
        if let doc = context.document, let ck = doc.citeKey {
            switch doc.contentType {
            case .pdf:
                parts.append("""
                    When citing content, use clickable citation links with the \
                    oak://cite/ scheme. For this PDF, use: \
                    [\(xmlEscape(doc.title)), p. N](oak://cite/\(xmlEscape(ck))?page=N) \
                    where N is the 1-based page number. You can narrow to specific \
                    text: [\(xmlEscape(doc.title)), p. N](oak://cite/\(xmlEscape(ck))?page=N&text=phrase). \
                    Only cite pages you have actually read or found via search tools.
                    """)
            case .html, .markdown:
                parts.append("""
                    When citing content, use clickable citation links with the \
                    oak://cite/ scheme. For this document, cite by heading: \
                    [\(xmlEscape(doc.title)), § Heading](oak://cite/\(xmlEscape(ck))?heading=HeadingText). \
                    For inline references, cite by text: \
                    [\(xmlEscape(doc.title)), "quoted"](oak://cite/\(xmlEscape(ck))?text=quoted+text). \
                    Do not use page numbers — this document has no pages.
                    """)
            case .video, .audio:
                parts.append("""
                    When citing content, use clickable citation links with the \
                    oak://cite/ scheme. For this media, cite by timestamp: \
                    [\(xmlEscape(doc.title)), MM:SS](oak://cite/\(xmlEscape(ck))?time=SECONDS) \
                    where SECONDS is the total seconds (e.g., 3:42 → time=222). \
                    Do not use page numbers — this is media content.
                    """)
            }
        } else if let doc = context.document {
            // No citeKey available — fallback without cite links
            parts.append("""
                This document has no citation key. You may reference content \
                descriptively but cannot create clickable citation links.
                """)
        }

        // Cross-document citation instructions (always apply when referenced docs exist)
        parts.append("""
            When the user's message contains a <referenced-documents> block, \
            use the `link` attribute from each <doc> element as the base URL. \
            Choose the right anchor based on the doc's `format` attribute: \
            for format="pdf" append ?page=N; \
            for format="html" or "markdown" append ?heading=Text or ?text=Text; \
            for format="video" or "audio" append ?time=SECONDS. \
            For referenced <note> elements, read them with the read tool using \
            the provided path. Only cite content you have actually read or found \
            via search tools.
            """)

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
}
