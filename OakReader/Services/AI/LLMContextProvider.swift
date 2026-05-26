import Foundation
import PDFKit
import OakAgent

/// Builds context snapshots and system prompts for the AI chat session.
struct LLMContextProvider {

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
            if let snapshot = vm.html {
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
                    // Check for article content saved by browser extension
                    let mdURL = media.fileURL.deletingLastPathComponent()
                        .appendingPathComponent("content.md")
                    if let md = try? String(contentsOf: mdURL, encoding: .utf8), !md.isEmpty {
                        currentPageText = String(md.prefix(4_000))
                    } else {
                        currentPageText = media.metadata.description ?? ""
                    }
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

        // Voice guidelines (loaded from ~/OakReader/agent/VOICE.md)
        if let voiceContent = try? String(contentsOf: CatalogDatabase.agentVoiceFileURL, encoding: .utf8),
           !voiceContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("<voice>\n\(voiceContent.trimmingCharacters(in: .whitespacesAndNewlines))\n</voice>")
        }

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
                path listed above. Use the oak tool to search the library \
                (oak search <query>), read any item's content \
                (oak items read <citeKey> --pages 1-5), list collections \
                (oak collections list), list tags (oak tags list), and manage items.
                """)

            // Abstract (outside document block to not crowd metadata)
            if let abstract = doc.abstract, !abstract.isEmpty {
                parts.append("Document abstract:\n\"\"\"\n\(String(abstract.prefix(2_000)))\n\"\"\"")
            }
        } else {
            // No document open — still inform the agent about available tools
            parts.append("""
                Use the oak tool to search the library (oak search <query>), \
                read any item's content (oak items read <citeKey> --pages 1-5), \
                list collections (oak collections list), list tags (oak tags list), \
                browse items (oak items list), and manage the library. \
                Use search_semantic for conceptual/thematic queries and \
                search_academic to find papers on the web.
                """)
        }

        // Citation link instructions — MUST use oak://cite/{citeKey} for all refs
        if let doc = context.document, let ck = doc.citeKey {
            let eck = xmlEscape(ck)

            // Core rule (imperative, prominent)
            parts.append("""
                IMPORTANT — Citation links: Every reference to document content \
                MUST be a clickable markdown link using the oak://cite/ scheme. \
                Never write bare page numbers like "page 5" or "p. 5" — always \
                wrap them in [link text](oak://cite/...). This applies to the \
                current document AND any cross-document references.
                """)

            // Format + example per document type
            switch doc.contentType {
            case .pdf:
                parts.append("""
                    This PDF's cite-key is "\(eck)". Citation format:
                    [p. N](oak://cite/\(eck)?page=N)
                    [p. N](oak://cite/\(eck)?page=N&text=phrase)

                    Prefer adding &text= with a distinctive 5-15 word phrase \
                    from the page so the reader can jump to the exact passage.

                    Example — notice every page mention is a link:
                    \"The transformer replaces recurrence with self-attention \
                    ([p. 2](oak://cite/\(eck)?page=2&text=entirely+on+attention+mechanisms)). \
                    The scaled dot-product formula is defined on \
                    [p. 3](oak://cite/\(eck)?page=3&text=Scaled+Dot-Product+Attention), and \
                    multi-head attention extends it on [p. 4](oak://cite/\(eck)?page=4).\"
                    """)
            case .html, .markdown:
                parts.append("""
                    This document's cite-key is "\(eck)". Citation format:
                    [§ Heading](oak://cite/\(eck)?heading=HeadingText)
                    ["quoted phrase"](oak://cite/\(eck)?text=quoted+text)

                    For ?text= use a distinctive 5-15 word phrase copied from \
                    the rendered text (not the raw markdown source). Matching \
                    is case-insensitive and tolerates whitespace differences, \
                    so focus on choosing a unique phrase rather than exact formatting.

                    Prefer ?text= for referencing specific passages; use \
                    ?heading= only when pointing to a whole section.

                    Example:
                    \"The API supports batch processing \
                    ([§ Batch Endpoints](oak://cite/\(eck)?heading=Batch%20Endpoints)), \
                    which the docs call 'fire-and-forget' \
                    (["fire-and-forget strategy"](oak://cite/\(eck)?text=fire-and-forget+strategy+for+asynchronous+jobs)).\"

                    Do not use page numbers — this document has no pages.
                    """)
            case .video, .audio:
                parts.append("""
                    This media's cite-key is "\(eck)". Citation format:
                    [MM:SS](oak://cite/\(eck)?time=SECONDS)

                    Example:
                    \"Gradient descent is introduced at \
                    [12:30](oak://cite/\(eck)?time=750) and backpropagation \
                    follows at [15:45](oak://cite/\(eck)?time=945).\"

                    Do not use page numbers — this is media content.
                    """)
            }

            // Cross-document references
            parts.append("""
                For cross-document references (from search_semantic, \
                oak search, or <referenced-documents> in the user message), \
                use the target document's cite-key:
                [citeKey, p. N](oak://cite/targetCiteKey?page=N)
                For <doc> elements, use the `link` attribute as the base URL and \
                append the appropriate anchor (?page=, ?heading=, ?text=, ?time=) \
                based on the doc's `format` attribute.
                For <note> elements, read them with the read tool using the \
                provided path.
                Only cite content you have actually read or found via tools.
                """)
        } else if context.document != nil {
            parts.append("""
                This document has no citation key. You may reference content \
                descriptively but cannot create clickable citation links.
                """)
        }

        // User profile and learning memory (personalization layer)
        let userMemoryBlock = Self.loadUserAndMemory()
        if !userMemoryBlock.isEmpty {
            parts.append("""
                \(userMemoryBlock)

                <memory-instructions>
                You maintain a dynamic cognitive map of the user's evolving understanding. \
                This is NOT a knowledge base — it tracks how their MIND changes.

                **Daily log (log_learning) — only when genuine learning signal:**
                - User confused, asked "why?", struggled, or got something wrong
                - User had insight, made cross-topic connection, or broke through
                - User's mental model visibly shifted
                Do NOT log: simple Q&A, routine tasks, things they already know.

                **Cognitive map (update_memory) — track structural changes:**
                - Mental model formed or replaced ("now thinks about X using Y framework")
                - Learning frontier moved (something at the edge became solid)
                - Misconception identified or resolved
                - Cross-domain connection discovered
                - Cognitive pattern observed (how they reason, not what they know)

                **Profile (update_user_profile) — durable identity facts:**
                - Background, goals, cognition targets, strengths, weaknesses

                Observe silently. Do not ask permission. Do not announce updates.
                </memory-instructions>
                """)
        }

        // Skill prompt (after context so the skill can reference it)
        if let skill {
            parts.append(skill.systemPrompt)
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - User Profile & Memory

    /// Load USER.md, MEMORY.md, and recent daily logs from ~/OakReader/agent/.
    /// Returns empty string if no files exist.
    private static func loadUserAndMemory() -> String {
        var sections: [String] = []

        let userURL = CatalogDatabase.agentUserFileURL
        if let userContent = try? String(contentsOf: userURL, encoding: .utf8),
           !userContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("<user-profile>\n\(userContent.trimmingCharacters(in: .whitespacesAndNewlines))\n</user-profile>")
        }

        let memoryURL = CatalogDatabase.agentMemoryFileURL
        if let memoryContent = try? String(contentsOf: memoryURL, encoding: .utf8),
           !memoryContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("<learning-memory>\n\(memoryContent.trimmingCharacters(in: .whitespacesAndNewlines))\n</learning-memory>")
        }

        // Load today's + yesterday's daily logs (like OpenClaw's temporal context)
        let dailyLogs = loadRecentDailyLogs()
        if !dailyLogs.isEmpty {
            sections.append("<recent-learning-log>\n\(dailyLogs)\n</recent-learning-log>")
        }

        return sections.joined(separator: "\n\n")
    }

    /// Load today and yesterday's daily learning logs (JSONL → readable format).
    private static func loadRecentDailyLogs() -> String {
        var logs: [String] = []
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
        let decoder = JSONDecoder()

        for date in [yesterday, today] {
            let url = CatalogDatabase.agentDailyLogURL(date: date)
            guard let content = try? String(contentsOf: url, encoding: .utf8),
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            var dayLines: [String] = ["## \(formatter.string(from: date))"]

            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let data = trimmed.data(using: .utf8),
                      let entry = try? decoder.decode(LearningLogEntry.self, from: data) else {
                    continue
                }
                let time = String(entry.timestamp.suffix(from:
                    entry.timestamp.index(entry.timestamp.startIndex, offsetBy: min(11, entry.timestamp.count))
                ).prefix(5))
                let doc = entry.document.map { " — \($0)" } ?? ""
                dayLines.append("- \(time) [\(entry.type)] #\(entry.subject) \(entry.entry)\(doc)")
            }

            if dayLines.count > 1 { // has entries beyond header
                logs.append(dayLines.joined(separator: "\n"))
            }
        }

        return logs.joined(separator: "\n\n")
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
