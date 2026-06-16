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
                itemCount: collection.itemCount,
                items: items,
                scopeId: isScopable ? collection.id.uuidString : nil
            )
        } else {
            activeCollection = nil
        }
        let workspacePath = (appState?.isAgentActive == true)
            ? appState?.agentWorkspaceDirectory?.path
            : nil

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
            agentWorkspacePath: workspacePath,
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
    /// A current-page passage injected as a citable `?c=` unit, sourced from the FTS
    /// index so its id resolves through the shared `ChunkCitationResolver`.
    struct CurrentPageChunk: Sendable {
        let id: Int64
        let page: Int?   // 0-based
        let text: String
    }

    static func buildSystemPrompt(
        skill: Skill?,
        context: ChatContextSnapshot,
        documentCharBudget: Int,
        currentPageChunks: [CurrentPageChunk] = []
    ) -> String {
        var parts: [String] = []

        // Base system prompt — a grounded, source-first research assistant.
        parts.append("""
            You are a grounded research assistant integrated into OakReader, a \
            document reader. Your job is to answer from the user's own sources — \
            the open document, their selection, the active collection, and passages \
            you retrieve — not from memory. Ground every substantive claim in those \
            sources and prefer retrieving over recalling.

            Citations are how the user verifies and jumps to the evidence, in the \
            form oak://cite/{citeKey}?page=N&text=<a verbatim quote from the \
            passage> (include &page= for documents and &time= for audio/video).

            What to cite — and what NOT to. A citation marks the EVIDENCE FOR A \
            CLAIM, not every sentence that touches a source. Cite: the thesis or \
            main conclusion of a passage you report; a specific claim, finding, or \
            causal statement ("X reduces Y by 40%"); named statistics, dates, \
            definitions, and direct quotations. Do NOT cite: transitions, generic \
            background, your own paraphrase of something you cited one sentence \
            earlier, restatements, or your own synthesis/reasoning. Prefer ONE \
            citation on the load-bearing claim over several on incidental phrases — \
            over-citing buries the source that actually matters. If a paragraph \
            makes one real claim, it usually needs one citation, on that claim's \
            sentence. Cite as you write, at the point of the claim — not as a \
            trailing list.

            Do not fabricate citations, quotes, or facts. If the sources don't \
            answer the question, say so plainly rather than guessing. Do not praise \
            questions or validate premises — if the user is wrong, say so directly. \
            If uncertain, say so. Do not change your answer under pressure unless new \
            evidence is presented.
            """)

        // Math formatting: this chat renders LaTeX, so math must use $/$$
        // delimiters — NOT code fences (which display source verbatim).
        parts.append("""
            Math formatting: this chat renders LaTeX. Write inline math as \
            $ ... $ and display/block math as $$ ... $$ (on their own lines). \
            Do NOT wrap formulas in ```latex or ```math code fences, and do NOT \
            use \\( ... \\) or \\[ ... \\] delimiters — those will not render. \
            Only use a code fence if the user explicitly asks to see the raw \
            LaTeX source rather than a rendered equation.
            """)

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
            // relevant). When the open page is indexed, inject it as numbered
            // [c<id>] passages so the model cites it by ?c= (validated, page-accurate)
            // exactly like retrieved passages; otherwise fall back to raw page text
            // (cited via ?text=). Bounded by the model-window budget either way.
            if !currentPageChunks.isEmpty {
                var lines = ["  <current-page index=\"\(doc.currentPageIndex + 1)\" note=\"each [c&lt;id&gt;] is a citable passage — cite it as oak://cite/CITEKEY?c=&lt;id&gt;&amp;text=&lt;verbatim claim sentence&gt;\">"]
                var remaining = documentCharBudget
                for ch in currentPageChunks where remaining > 0 {
                    let snippet = String(ch.text.prefix(remaining))
                    lines.append("    [c\(ch.id)] \(snippet)")
                    remaining -= snippet.count
                }
                lines.append("  </current-page>")
                docParts.append(lines.joined(separator: "\n"))
            } else if !doc.currentPageText.isEmpty {
                let truncated = String(doc.currentPageText.prefix(documentCharBudget))
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
                search (search_content). Use the read tool to read note files by their \
                path listed above. Use the oak tool to search the library \
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
                Use search_content for conceptual/thematic queries and \
                search_academic to find papers on the web.

                Cite every claim. When you cite a passage returned by search_content \
                or research, it carries a "Cite this passage as: ?c=<id>" handle — \
                cite using that id and copy the single sentence that states the claim:
                [your own label](oak://cite/{citeKey}?c=<id>&text=<verbatim claim sentence>)
                The app resolves the id to the exact page and verifies the quote. The \
                [label] is your own wording; the ?text= value is copied word-for-word. \
                Cite the load-bearing claim, not incidental phrases — one cite per claim.
                """)
        }

        // Agent workspace — the chat's working directory, with mounted documents.
        if let wsPath = context.agentWorkspacePath {
            parts.append("""
                <workspace path="\(xmlEscape(wsPath))" />
                You are working inside an agent workspace folder — your current \
                working directory. The documents for this workspace are mounted \
                here as editable copies (relative paths resolve to this folder). \
                Read and edit them in place with the read/write/ls tools, and save \
                any new content you produce (notes, drafts, summaries) as files in \
                this folder.
                """)
        }

        // GROUNDED mode — scoped to a real collection. Retrieval (search_content /
        // research) is already PHYSICALLY restricted to this collection's members,
        // so the model cannot accidentally pull from the rest of the library.
        if let collection = context.activeCollection, collection.isScopable {
            let name = collection.name
            let countText = collection.itemCount.map { " (\($0) sources)" } ?? ""
            parts.append("""
                GROUNDED MODE — you are scoped to the "\(xmlEscape(name))" collection\(countText).
                Answer ONLY from the documents in this collection. Retrieve before \
                you answer: use search_content and research (both already restricted \
                to this collection) and `oak items read <citeKey> --pages N-M` to pull \
                the actual passages, then cite each claim with oak://cite/... so the \
                user can jump to the exact spot.

                If this collection does not contain the answer, say so explicitly \
                first — e.g. "The sources in \(xmlEscape(name)) don't cover this." \
                Only then, and only prefixed with "Beyond your sources:", may you add \
                general knowledge — never blend it in silently. Do not search the web \
                or the wider library unless the user explicitly asks you to.
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

            // Verbatim-anchor rule — the #1 cause of citations that don't highlight is a
            // paraphrased ?text=. The visible label may be your own words, but the anchor
            // must be an exact quote so the reader can locate it in the document.
            parts.append("""
                CRITICAL — The ?text= (and ?heading=) anchor MUST be copied \
                VERBATIM from the document: an exact, contiguous run of words as \
                it literally appears — same spelling, numbers, capitalization and \
                punctuation. Do NOT paraphrase, summarize, reorder, abbreviate \
                (e.g. "36 million" not "36M"), or stitch together non-adjacent \
                words for the anchor. Anchor on the CLAIM, not a catchy fragment: \
                copy the clause or sentence that actually states the point you are \
                citing (the span a reader would underline as "this is it"), exactly \
                as it appears — typically a full clause up to one sentence (line \
                breaks inside the quote are fine). Do not shrink it to a short, \
                quotable noun-phrase just because that is easier to copy. If the \
                claim sentence is long, anchor on its core assertion (subject + verb \
                + object), still a single contiguous verbatim run. The link's \
                visible [label] can be your own wording; only the anchor value must \
                be the quote. If you are not certain of the exact wording, omit \
                ?text= and cite the page alone — never invent a phrase.
                """)

            // Format + example per citation style. A live web page is `.link` with
            // no timeline, so it cites like HTML (textual) rather than by `?time=`.
            enum CitationStyle { case paged, textual, timeline }
            let style: CitationStyle
            switch doc.contentType {
            case .pdf:                  style = .paged
            case .html, .markdown:      style = .textual
            case .link:                 style = doc.isTimelineMedia ? .timeline : .textual
            case .audio:                style = .timeline
            }

            switch style {
            case .paged:
                parts.append("""
                    This PDF's cite-key is "\(eck)". Citation format:
                    [p. N](oak://cite/\(eck)?page=N)
                    [p. N](oak://cite/\(eck)?page=N&text=verbatim+quote)

                    Add &text= with the verbatim clause or sentence that states the \
                    claim (not a catchy fragment), copied from that page (spaces \
                    encoded as +) so the reader jumps to the load-bearing passage. \
                    The quote must appear word-for-word on the page; if you can't \
                    quote it exactly, give the page alone.

                    If the <current-page> above is shown as [c<id>] passages, cite \
                    those by oak://cite/\(eck)?c=<id>&text=<claim sentence> rather \
                    than writing the page number yourself — the app resolves the id \
                    to the exact page and verifies the quote.

                    Example — the [label] is paraphrased, the &text= anchor is an exact quote:
                    \"The transformer replaces recurrence with self-attention \
                    ([p. 2](oak://cite/\(eck)?page=2&text=based+solely+on+attention+mechanisms)). \
                    The scaled dot-product formula is defined on \
                    [p. 3](oak://cite/\(eck)?page=3&text=Scaled+Dot-Product+Attention), and \
                    multi-head attention extends it on [p. 4](oak://cite/\(eck)?page=4).\"
                    """)
            case .textual:
                parts.append("""
                    This document's cite-key is "\(eck)". Citation format:
                    [§ Heading](oak://cite/\(eck)?heading=HeadingText)
                    [your own label](oak://cite/\(eck)?text=verbatim+claim+sentence)

                    For ?text= copy the clause or sentence that STATES THE CLAIM \
                    you're citing — not a catchy fragment — VERBATIM from the \
                    rendered text (not the raw markdown source), exact words in \
                    order, no paraphrasing. Matching is case-insensitive, so only \
                    casing may differ; the words themselves must match the page. The \
                    [label] is your own wording; the anchor is the quote.

                    Prefer ?text= for referencing specific passages; use \
                    ?heading= only when pointing to a whole section.

                    Example — the label names the idea, the anchor is the claim sentence:
                    \"Batch jobs are processed asynchronously \
                    ([§ Batch Endpoints](oak://cite/\(eck)?heading=Batch%20Endpoints)), \
                    and the docs guarantee completion \
                    ([within 24 hours](oak://cite/\(eck)?text=batch+jobs+are+processed+asynchronously+within+24+hours)).\"

                    Do not use page numbers — this document has no pages.
                    """)
            case .timeline:
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
                For cross-document references (from search_content, \
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

            // Chunk-id citations for retrieved passages — the most reliable anchor.
            parts.append("""
                PREFERRED — When you cite a passage returned by search_content or \
                research, it carries a "Cite this passage as: ?c=<id>" handle. Cite \
                using that id and copy the single sentence that states the claim:
                [your own label](oak://cite/{citeKey}?c=<id>&text=<verbatim claim sentence>)
                The app resolves the id to the exact page and verifies the quote, so \
                this is more reliable than writing a page number yourself. The \
                [label] is your own wording; the ?text= value must be copied \
                word-for-word from that passage.
                """)
        } else if context.document != nil {
            parts.append("""
                This document has no citation key. You may reference content \
                descriptively but cannot create clickable citation links.
                """)
        }

        // User profile + memory instructions. Two lanes, split by initiator:
        // passive facts the agent merely notices are consolidated automatically in
        // the background; the `manage_memory` tool is ONLY for explicit user
        // requests. The instructions are always emitted (even with empty memory) so
        // the agent knows to honor "add … to my memory" on a fresh profile.
        var memoryParts: [String] = []
        let userProfileBlock = Self.loadUserProfile()
        if !userProfileBlock.isEmpty { memoryParts.append(userProfileBlock) }
        memoryParts.append("""
            <memory-instructions>
            The <user-profile> above (when present) is who the user is — use it to \
            tailor depth, examples, and tone. It is maintained automatically in the \
            background; do NOT proactively save things you merely noticed, and do not \
            announce background updates.
            Use the `manage_memory` tool ONLY when the user EXPLICITLY asks you to \
            view, add, change, or remove a memory — e.g. "remember that …", "add … to \
            my memory", "what do you remember about me?", "update …", "forget …". \
            For add/update/remove, briefly confirm in plain language what you saved, \
            updated, or removed. Default scope is the user's global memory; use scope \
            "item" for a note about the document currently open.
            </memory-instructions>
            """)
        parts.append(memoryParts.joined(separator: "\n\n"))

        // Skill prompt (after context so the skill can reference it)
        if let skill {
            parts.append(skill.systemPrompt)
        }

        return parts.joined(separator: "\n\n")
    }

    // MARK: - User Profile & Per-Document Brief

    /// Load the user profile (discrete facts). Returns empty string if none.
    private static func loadUserProfile() -> String {
        let rendered = MemoryStore.rendered(.user)
        guard !rendered.isEmpty else { return "" }
        return "<user-profile>\n\(rendered)\n</user-profile>"
    }

    /// Load the per-document continuity brief for an item, wrapped for the prompt.
    /// Injected ONLY when that item is the open document, so memory about one
    /// document never pollutes a conversation about another. Returns nil if none.
    static func loadItemBrief(itemId: String) -> String? {
        let rendered = MemoryStore.rendered(.item(itemId))
        guard !rendered.isEmpty else { return nil }
        return """
            <previous-sessions note="Notes from your earlier chats about THIS document. \
            Use them to pick up where you left off; they may be stale or incomplete.">
            \(rendered)
            </previous-sessions>
            """
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
