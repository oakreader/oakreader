import Foundation
import PDFKit
import OakAgent

/// Builds context snapshots and system prompts for the AI chat session.
struct LLMContextProvider {

    // MARK: - Context Snapshot

    /// How many characters of document body text to embed in the prompt, derived
    /// from the active model's context window. Replaces the old fixed 4 000-char
    /// cap so a whole short document (e.g. a 20-page PDF) loads in full on a large
    /// window, while small local-model windows stay bounded.
    ///
    /// Heuristic: spend ~40% of the window on the open document, at ~3 chars/token
    /// (conservative for mixed Latin/CJK text). Floored so even tiny windows beat
    /// the old 4 000-char cap. The 40% fraction is a starting point — see
    /// `docs/backlog/citation-grounding-redesign.md` (open decision).
    static func documentCharBudget(contextWindow: Int) -> Int {
        let docTokens = max(2_000, Int(Double(contextWindow) * 0.4))
        return docTokens * 3
    }

    /// Build a ``ChatContextSnapshot`` capturing all app + document context for the AI.
    /// `documentCharBudget` bounds how much body text each source contributes; pass
    /// the value from ``documentCharBudget(contextWindow:)`` for the active model.
    static func buildContextSnapshot(
        from documentVM: DocumentViewModel?,
        appState: AppState?,
        contextMode: ContextMode,
        documentCharBudget: Int
    ) -> ChatContextSnapshot {
        // App-level context — the selected collection, if any.
        let activeCollection: ChatContextSnapshot.ActiveCollection?
        if let collection = appState?.libraryStore.selectedCollection {
            // Scope only to real user collections (not smart, not "All Items").
            // The id matches `collection_items.collection_id` (both UUID().uuidString).
            let isScopable = !collection.isSmart && collection.id != SystemCollectionID.allItems
            let items = appState?.libraryStore.filteredItems.prefix(50).map {
                ChatContextSnapshot.CollectionItemSummary(
                    title: $0.title, author: $0.author, citeKey: $0.citeKey
                )
            } ?? []
            activeCollection = ChatContextSnapshot.ActiveCollection(
                name: collection.name,
                // Smart/system collections (Reading List, Duplicates, Bin, rule-based)
                // have no rows in `collection_items`, so the static `collection.itemCount`
                // is 0. Resolve the real membership count instead.
                itemCount: appState?.libraryStore.smartCollectionItemCount(for: collection)
                    ?? collection.itemCount,
                items: items,
                scopeId: isScopable ? collection.id.uuidString : nil
            )
        } else {
            activeCollection = nil
        }
        let openTabTitles = appState?.openTabs.map(\.title) ?? []
        let activeTabTitle = appState?.activeTab?.title

        // Document context
        let docContext: ChatContextSnapshot.DocumentContext?
        if let vm = documentVM {
            docContext = buildDocumentContext(from: vm, contextMode: contextMode, charBudget: documentCharBudget)
        } else {
            docContext = nil
        }

        return ChatContextSnapshot(
            activeCollection: activeCollection,
            openTabTitles: openTabTitles,
            activeTabTitle: activeTabTitle,
            document: docContext
        )
    }

    private static func buildDocumentContext(
        from vm: DocumentViewModel,
        contextMode: ContextMode,
        charBudget: Int
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
                    currentPageText = String(md.prefix(charBudget))
                } else if let data = try? Data(contentsOf: snapshot.htmlURL) {
                    currentPageText = String(
                        HTMLTextExtractor.extractText(from: data).prefix(charBudget)
                    )
                } else {
                    currentPageText = ""
                }
            } else {
                currentPageText = ""
            }
        case .link:
            if let media = vm.mediaDocument {
                if let url = media.transcriptURL,
                   let text = try? String(contentsOf: url, encoding: .utf8) {
                    currentPageText = String(text.prefix(charBudget))
                } else {
                    // Check for article content saved by browser extension
                    let mdURL = media.storageDirectory
                        .appendingPathComponent("content.md")
                    if let md = try? String(contentsOf: mdURL, encoding: .utf8), !md.isEmpty {
                        currentPageText = String(md.prefix(charBudget))
                    } else {
                        currentPageText = media.metadata.description ?? ""
                    }
                }
            } else {
                currentPageText = ""
            }
        case .markdown:
            if let mdDoc = vm.markdownDocument {
                currentPageText = String(mdDoc.content.prefix(charBudget))
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

        // A `.link` is a timeline medium (cite by `?time=`) only when it carries a
        // duration/YouTube embed; a live web page is `.link` with no timeline and is
        // cited like HTML. `.audio` is always a timeline medium.
        let isTimelineMedia = vm.contentType == .audio
            || (vm.mediaDocument.map {
                $0.metadata.resolvedEmbedType == .youtube || $0.metadata.duration != nil
            } ?? false)

        return ChatContextSnapshot.DocumentContext(
            fileName: vm.fileName,
            filePath: filePath,
            contentType: vm.contentType,
            isTimelineMedia: isTimelineMedia,
            pageCount: pageCount,
            currentPageIndex: currentPageIndex,
            currentPageText: currentPageText,
            selectedText: vm.state.selectedText,
            itemId: item?.id.uuidString,
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
            pages: csl?.page
        )
    }

    // MARK: - System Prompt

    /// Build a system prompt from a skill and enriched context snapshot.
    /// Uses structured XML for metadata, includes current page text, and references
    /// available tools for on-demand document reading.
    /// Build a system prompt: the core's composed policy text, then the live
    /// context only the shell can know.
    ///
    /// The split is the point. Policy is prose in `prompts/`, editable without
    /// a rebuild. Context — the open document, the active collection, the tab
    /// list — is assembled here because nothing else has it.
    static func buildSystemPrompt(
        staticPrompt: String,
        skill: Skill?,
        context: ChatContextSnapshot,
        documentCharBudget: Int,
        sources: CitationSourceRegistry
    ) -> String {
        var parts: [String] = []

        // The static half — who the assistant is, how it formats maths — now
        // lives in prompts/ and is composed by the core. `staticPrompt` is
        // passed in rather than fetched here so this stays synchronous: it is
        // called while assembling a turn, and the files are read once per turn
        // by the caller.
        if !staticPrompt.isEmpty { parts.append(staticPrompt) }

        // Voice guidelines (loaded from ~/OakReader/agent/VOICE.md)
        if let voiceContent = try? String(contentsOf: CatalogDatabase.agentVoiceFileURL, encoding: .utf8),
           !voiceContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("<voice>\n\(voiceContent.trimmingCharacters(in: .whitespacesAndNewlines))\n</voice>")
        }

        // App context
        var appContextParts: [String] = []
        if let collection = context.activeCollection {
            let countAttr = collection.itemCount.map { " items=\"\($0)\"" } ?? ""
            if collection.items.isEmpty {
                appContextParts.append("  <active-collection name=\"\(xmlEscape(collection.name))\"\(countAttr) />")
            } else {
                var lines: [String] = []
                lines.append("  <active-collection name=\"\(xmlEscape(collection.name))\"\(countAttr)>")
                for item in collection.items {
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

            // Selected text
            if let selected = doc.selectedText, !selected.isEmpty {
                docParts.append("  <selected-text>\n\(selected)\n  </selected-text>")
            }

            // Current page / document body text (always include — immediately
            // relevant). Bounded by the model-window budget.
            //
            // Numbered on the way in, so every passage the model can see is already
            // citable as `oak:N` and it never has to reproduce the text to point at it.
            if !doc.currentPageText.isEmpty {
                let truncated = String(doc.currentPageText.prefix(documentCharBudget))
                let numbered = sources.numbered(
                    truncated,
                    itemId: doc.itemId ?? "",
                    // A paged document locates the passage by page; a timeline medium by
                    // its transcript timecodes, which we don't have here, so it falls back
                    // to a whole-document anchor until the read tool supplies them.
                    page: doc.contentType == .pdf ? doc.currentPageIndex : nil
                )
                docParts.append("  <current-page index=\"\(doc.currentPageIndex + 1)\">\n\(numbered)\n  </current-page>")
            }

            let docBlock = docParts.joined(separator: "\n")
            parts.append(
                "<document type=\"\(xmlEscape(doc.contentType.rawValue))\" pages=\"\(doc.pageCount)\">\n\(docBlock)\n</document>"
            )

            // Tool usage hint
            parts.append("""
                You have tools to read document pages (read_document) and search within \
                the document (search_document). Use the read tool to read note files by \
                their path listed above. Use the oak tool to search the library \
                (oak search <query>), read any item's content \
                (oak items read <citeKey> --pages 1-5), list collections \
                (oak collections list), list tags (oak tags list), and manage items.
                """)

            // Browser-mode hint — the user is viewing a live web page (.link).
            if doc.contentType == .link {
                parts.append("""
                    The user is viewing a LIVE web page in the browser. Use read_current_page \
                    to get its content as readable markdown — this reads the rendered, \
                    logged-in DOM the user actually sees, so prefer it over fetch_web_content \
                    for anything about the page on screen, and never fetch the current page's \
                    own URL. Use fetch_web_content only for OTHER URLs (links on the page, \
                    search results, URLs the user names).
                    """)
            }

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
                Use search_academic to find papers on the web.

                """)
        }

        // Referenced documents (the user's `@`-mentions). These arrive as a
        // <referenced-documents> block in the user message carrying only metadata —
        // the body is NOT inlined. The model must fetch it itself rather than ask the
        // user to summarize or open it.
        parts.append("""
            When the user message contains a <referenced-documents> block, the user has \
            attached those library documents as context. Only their metadata is given — \
            NOT their text. Before answering anything about a referenced document, READ \
            it yourself: call `oak items read "<title-or-cite-key>" [--pages N-M]` (use \
            the <doc> element's `read-with` attribute, or its title / cite-key), and \
            `search <query>` to locate a passage. Never reply that you "haven't read it" \
            or ask the user to summarize/open it — you have the tools, so use them, then \
            answer, citing the numbered passages they return.
            """)

        // GROUNDED mode — scoped to a real collection. The scope is instructional:
        // the model is told to answer only from this collection's documents.
        if let collection = context.activeCollection, collection.isScopable {
            let name = collection.name
            let countText = collection.itemCount.map { " (\($0) sources)" } ?? ""
            parts.append("""
                GROUNDED MODE — you are scoped to the "\(xmlEscape(name))" collection\(countText).
                Answer ONLY from the documents in this collection. Read before \
                you answer: use `oak search <query>` and \
                `oak items read <citeKey> --pages N-M` to pull the actual passages, \
                then cite each claim by its passage number so the user can jump to \
                the exact spot.

                If this collection does not contain the answer, say so explicitly \
                first — e.g. "The sources in \(xmlEscape(name)) don't cover this." \
                Only then, and only prefixed with "Beyond your sources:", may you add \
                general knowledge — never blend it in silently. Do not search the web \
                or the wider library unless the user explicitly asks you to.
                """)
        }

        // Citation format. The whole wire protocol is one number: passages arrive in
        // context already numbered (see CitationSourceRegistry), and the model cites one
        // by linking its number. It never reproduces a quote, a page, or a cite key, so
        // the anchor cannot be paraphrased, mis-encoded, or invented — which is what the
        // ~4 KB of "copy the anchor VERBATIM" rules this replaced were trying to prevent.
        parts.append("""
            Citations. Passages you are shown are numbered like [14]. Cite one by \
            linking its number: [your own label](oak:14). Only ever cite a number you \
            were actually shown — never invent one, and never write a bare page number \
            like "p. 5" instead of a link.

            Cite the load-bearing claim: a quotation, a statistic, a named finding, or \
            the conclusion of a passage you are summarizing. Do not cite your own \
            reasoning, generic background, or ordinary conversation. At most one \
            citation per sentence, placed at the end — never make the whole sentence \
            the link, and never end an answer with a list of citations.
            """)

        // User memory (ChatGPT `bio`-style): one global profile of durable facts
        // about the user, injected into every conversation. The `manage_memory`
        // tool writes to it inline — proactively when the user shares something
        // lasting, and on explicit request. Gated by the memory toggle; when off,
        // neither the profile nor the instructions (nor the tool) are present.
        if Preferences.shared.memoryEnabled {
            var memoryParts: [String] = []
            let userProfileBlock = Self.loadUserProfile()
            if !userProfileBlock.isEmpty { memoryParts.append(userProfileBlock) }
            memoryParts.append("""
                <memory-instructions>
                The <user-profile> above (when present) is who the user is — use it to \
                tailor depth, examples, and tone.
                You can remember durable facts about the user across conversations with \
                the `manage_memory` tool. Save a fact when the user shares something \
                lasting and useful about themselves (background, goals, what they're \
                studying, durable preferences for how they want answers), and whenever \
                they explicitly ask you to ("remember that …", "forget …"). Don't save \
                transient or document-specific details. When the user explicitly asked, \
                briefly confirm what you changed; when you save on your own initiative, \
                do it silently.
                </memory-instructions>
                """)
            parts.append(memoryParts.joined(separator: "\n\n"))
        }

        // Skill prompt (after context so the skill can reference it)
        if let skill {
            parts.append(skill.systemPrompt)
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - User Profile

    /// Load the user profile (discrete facts). Returns empty string if none.
    private static func loadUserProfile() -> String {
        let rendered = MemoryStore.rendered()
        guard !rendered.isEmpty else { return "" }
        return "<user-profile>\n\(rendered)\n</user-profile>"
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
