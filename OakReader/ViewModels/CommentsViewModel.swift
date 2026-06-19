import Foundation

/// Drives the right-panel **Comments** stream for a single document — a
/// chat-to-self, capture-first list. It surfaces every comment-bearing annotation
/// row for the doc in one chronological stream (oldest first, newest at bottom):
///   • freestanding **memos** (`positionKind == "memo"`, no anchor),
///   • selection-anchored notes (`pdf-overlay` / `web`, with a quoted source).
///
/// Reuses the shared `annotations` table (no migration): a memo is just a row
/// whose `comment` is set and whose `positionKind` is `"memo"`.
@Observable
final class CommentsViewModel {
    weak var parent: DocumentViewModel?

    /// All comment cards for the current doc, oldest first (newest at the bottom).
    /// Chat-to-self model: you jot at the bottom and the stream grows downward,
    /// like Telegram Saved Messages / 微信文件传输助手.
    var cards: [AnnotationRecord] = []
    var isLoaded = false

    /// When set, the stream shows only cards carrying this `#tag`. Document-scoped:
    /// for a long, note-dense doc (a book / long paper) the per-doc note list IS a
    /// corpus worth filtering. Cleared automatically when the tag no longer exists
    /// (last note bearing it deleted) or when a new memo is added.
    var activeTagFilter: String?

    /// Free-text filter over the stream (matches note body + its tags, case-
    /// insensitive). Combines with `activeTagFilter`.
    var searchQuery: String = ""

    /// Distinct `#tags` across all cards in this doc, most-used first (ties → name).
    /// Drives the filter bar; only worth showing when there are ≥2 distinct tags.
    var allTags: [String] {
        var counts: [String: Int] = [:]
        for card in cards {
            for tag in NoteTags.extract(card.comment ?? "") { counts[tag, default: 0] += 1 }
        }
        return counts.keys.sorted { a, b in
            counts[a]! != counts[b]! ? counts[a]! > counts[b]! : a < b
        }
    }

    /// Cards after applying the tag filter and the free-text search (either/both,
    /// or neither). Text matches the note's clean body plus its tag names.
    var filteredCards: [AnnotationRecord] {
        var result = cards
        if let tag = activeTagFilter {
            result = result.filter { NoteTags.extract($0.comment ?? "").contains(tag) }
        }
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            result = result.filter { card in
                let raw = card.comment ?? ""
                let body = NoteTags.preview(NoteComposerBox.splitBody(raw).text)
                let tags = NoteTags.extract(raw).joined(separator: " ")
                return "\(body) \(tags)".lowercased().contains(q)
            }
        }
        return result
    }

    /// Whether any filter (tag or text) is narrowing the stream.
    var isFiltering: Bool {
        activeTagFilter != nil || !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Toggle the stream's tag filter (tap the active tag again to clear it).
    func toggleTagFilter(_ tag: String) {
        activeTagFilter = (activeTagFilter == tag) ? nil : tag
    }

    /// When set, the composer is writing the note for this just-created highlight
    /// (vs. a freestanding memo). `pendingQuote` is the highlighted source text,
    /// shown as a chip above the input.
    var pendingAnchorId: String?
    var pendingQuote: String?

    /// When set, the panel scrolls to + flashes this card (clicking a highlight
    /// or its sidebar entry). Cleared once consumed by the view.
    var focusedCardId: String?

    /// A region capture (viewer crosshair) finished — its persisted `file://`
    /// URL for the active composer to insert as a markdown image. Cleared once
    /// the composer consumes it.
    var pendingCaptureURL: String?

    /// Retains the create composer's already-booted Milkdown `WKWebView` so
    /// re-entering the Notes tab reuses it instead of reloading (which caused the
    /// boot+fade "flick"). View-layer plumbing, not observable note state.
    @ObservationIgnored let composerWebHolder = ComposerWebHolder()

    /// Route a finished area capture into the active note composer.
    func deliverCapturedImage(_ url: String) {
        pendingCaptureURL = url
    }

    init(parent: DocumentViewModel?) {
        self.parent = parent
    }

    private var store: AnnotationStore? {
        guard let db = parent?.database else { return nil }
        return AnnotationStore(database: db)
    }

    /// A card points at something in the document (vs a freestanding memo).
    func isAnchored(_ record: AnnotationRecord) -> Bool {
        record.positionKind != "memo"
    }

    // MARK: - Load

    func reload() {
        guard let store, let attId = parent?.attachmentId else {
            cards = []
            isLoaded = true
            return
        }
        cards = store.fetch(attachmentId: attId)
            .filter {
                $0.deletedAt == nil
                    && ($0.comment?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            }
            .sorted { $0.createdAt < $1.createdAt }
        isLoaded = true
        // Drop a filter whose tag no longer exists (its last note was deleted/edited).
        if let tag = activeTagFilter, !allTags.contains(tag) { activeTagFilter = nil }
    }

    // MARK: - Anchored capture (selection → panel)

    /// Begin writing the note for a freshly-created highlight. The highlight row
    /// already exists (empty comment); the composer commits the text into it.
    func startNote(forAnnotationId id: String) {
        pendingAnchorId = id
        pendingQuote = store?.fetch(id: id)?.text
        focusedCardId = nil
        reload()
    }

    func cancelPending() {
        pendingAnchorId = nil
        pendingQuote = nil
    }

    /// Save the composer text into the pending highlight's comment. The anchored
    /// highlight row already exists, so this never needs to import a backing item.
    @discardableResult
    func commitPending(_ text: String) -> Bool {
        guard let id = pendingAnchorId else { return false }
        let ok = updateComment(id: id, text: text)
        if ok { cancelPending() }
        return ok
    }

    /// Ask the panel to scroll to + flash an existing card.
    func focusCard(id: String) {
        pendingAnchorId = nil
        focusedCardId = id
        reload()
    }

    // MARK: - Mutations

    /// Ensure this document has a backing library item to attach notes to.
    ///
    /// Live web pages (browser-mode tabs reached from the omnibox) start with no
    /// item/attachment — `attachmentId`/`itemId` are nil — so a freestanding memo
    /// had nowhere to persist and was silently dropped. The first note now
    /// lazy-imports the live page into the library (the same `importBrowserLink`
    /// flow the toolbar's "Save" button uses), then adopts the new ids on this
    /// tab. Returns true once both ids exist.
    @MainActor
    private func ensureBackingItem() async -> Bool {
        if parent?.attachmentId != nil, parent?.itemId != nil { return true }
        guard let parent,
              let importService = parent.appState?.importService,
              let url = parent.state.currentURL ?? parent.liveURL,
              url.scheme?.lowercased().hasPrefix("http") == true else { return false }

        // Best-effort readable enrichment; importBrowserLink works without it.
        let readable = await LivePageBridge.shared.extractReadable(maxChars: 1_000_000)
        guard let item = await importService.importBrowserLink(
            url, liveTitle: readable?.title, liveMarkdown: readable?.markdown
        ) else { return false }

        parent.itemStorageKey = item.storageKey
        parent.attachmentId = item.primaryAttachment?.id.uuidString
        return parent.attachmentId != nil && parent.itemId != nil
    }

    /// Create a freestanding memo (no text selection needed). Lazily promotes a
    /// live web page into a library item first so the memo has somewhere to live.
    @discardableResult
    func addMemo(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard await ensureBackingItem() else { return false }
        guard let store,
              let attId = parent?.attachmentId,
              let itmId = parent?.itemId else { return false }

        // A just-jotted note may not match the active filter/search — clear both so
        // it isn't hidden the moment it's created.
        activeTagFilter = nil
        searchQuery = ""

        let now = Date().iso8601String
        let record = AnnotationRecord(
            id: UUID().uuidString,
            userId: localUserId,
            itemId: itmId,
            attachmentId: attId,
            key: AnnotationStore.generateKey(),
            type: "note",
            authorName: nil,
            text: nil,
            comment: text,
            color: "#ffd400",
            pageLabel: nil,
            sortIndex: "00000|000000|000000",
            positionKind: "memo",
            positionJson: "{}",
            styleJson: nil,
            source: "oakreader",
            sourceKey: nil,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )
        store.upsert(record)
        reload()
        postChanged()
        return true
    }

    /// Edit a card's comment text. Clearing it drops the card from the stream;
    /// for anchored notes the highlight row itself stays (just uncommented).
    @discardableResult
    func updateComment(id: String, text: String) -> Bool {
        guard let store, var record = store.fetch(id: id) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        record.comment = trimmed.isEmpty ? nil : text
        record.updatedAt = Date().iso8601String
        store.upsert(record)
        reload()
        postChanged()
        return true
    }

    /// Delete a card. Anchored cards also drop their on-page highlight.
    func delete(_ record: AnnotationRecord) {
        switch record.positionKind {
        case "pdf-overlay":
            // Removes the DB row + the overlay markup + refreshes (also posts change).
            parent?.annotation.deleteOverlayMarkup(id: record.id)
        case "web":
            store?.softDelete(id: record.id)
            NotificationCenter.default.post(
                name: .webDeleteHighlight, object: parent, userInfo: ["id": record.id]
            )
        default:  // "memo"
            store?.softDelete(id: record.id)
        }
        reload()
        postChanged()
    }

    /// A plain-text `NoteRef` (preview + time) for a card, for pickers / backlinks.
    private func noteRef(_ record: AnnotationRecord) -> NoteRef {
        let raw = record.comment ?? ""
        // Drop images, then tags + collapse `[label](url)` links to clean text.
        let preview = NoteTags.preview(NoteComposerBox.splitBody(raw).text)
        return NoteRef(id: record.id, preview: preview,
                       time: NoteTime.absolute(record.createdAt))
    }

    /// The memos the `@` reference picker can link to (every other card in this
    /// doc), newest first, with a plain-text preview for matching/display.
    func referenceableMemos(excluding excludeId: String?) -> [NoteRef] {
        cards.compactMap { $0.id == excludeId ? nil : noteRef($0) }
    }

    /// Notes in this doc that reference the given card (`oak-note://<id>` in their
    /// body) — the backlinks shown on the referenced memo. Derived in-memory from
    /// the already-loaded cards; no relation table needed.
    func backlinks(to id: String) -> [NoteRef] {
        let href = NoteLink.href(id)
        return cards.compactMap { record in
            guard record.id != id, (record.comment ?? "").contains(href) else { return nil }
            return noteRef(record)
        }
    }

    /// The full records (not just previews) of the notes that reference the given
    /// card — backing the flomo-style "Note Detail" popup, which renders each
    /// referencing note in full rather than as a one-line backlink.
    func backlinkRecords(to id: String) -> [AnnotationRecord] {
        let href = NoteLink.href(id)
        return cards.filter { $0.id != id && ($0.comment ?? "").contains(href) }
    }

    /// Look up a single card record by id (for the detail popup's left column).
    func card(id: String) -> AnnotationRecord? {
        cards.first { $0.id == id }
    }

    /// Scroll the document to a card's source and surface it.
    func jump(_ record: AnnotationRecord) {
        switch record.positionKind {
        case "web":
            NotificationCenter.default.post(
                name: .webViewFocusHighlight, object: parent, userInfo: ["id": record.id]
            )
        case "pdf-overlay":
            if let (pageIndex, _) = parent?.markupOverlay.markup(withId: record.id) {
                parent?.viewer.goToPage(pageIndex)
                // Notes leave no persistent highlight, so flash the source range
                // to reveal where the note came from.
                parent?.markupOverlay.flash(id: record.id)
            }
        default:
            break  // memo: no anchor to jump to
        }
    }

    private func postChanged() {
        NotificationCenter.default.post(name: .commentsDidChange, object: parent)
    }
}
