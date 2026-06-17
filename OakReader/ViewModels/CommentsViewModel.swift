import Foundation

/// Drives the right-panel **Comments** stream for a single document — a
/// flomo-style, capture-first list. It surfaces every comment-bearing annotation
/// row for the doc in one reverse-chronological stream:
///   • freestanding **memos** (`positionKind == "memo"`, no anchor),
///   • selection-anchored notes (`pdf-overlay` / `web`, with a quoted source).
///
/// Reuses the shared `annotations` table (no migration): a memo is just a row
/// whose `comment` is set and whose `positionKind` is `"memo"`.
@Observable
final class CommentsViewModel {
    weak var parent: DocumentViewModel?

    /// All comment cards for the current doc, newest first.
    var cards: [AnnotationRecord] = []
    var isLoaded = false

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
            .sorted { $0.createdAt > $1.createdAt }
        isLoaded = true
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

    /// Save the composer text into the pending highlight's comment.
    func commitPending(_ text: String) {
        guard let id = pendingAnchorId else { return }
        updateComment(id: id, text: text)
        cancelPending()
    }

    /// Ask the panel to scroll to + flash an existing card.
    func focusCard(id: String) {
        pendingAnchorId = nil
        focusedCardId = id
        reload()
    }

    // MARK: - Mutations

    /// Create a freestanding memo (no text selection needed).
    @discardableResult
    func addMemo(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let store,
              let attId = parent?.attachmentId,
              let itmId = parent?.itemId else { return false }

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
            isExternal: false,
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
    func updateComment(id: String, text: String) {
        guard let store, var record = store.fetch(id: id) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        record.comment = trimmed.isEmpty ? nil : text
        record.updatedAt = Date().iso8601String
        store.upsert(record)
        reload()
        postChanged()
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
            }
        default:
            break  // memo: no anchor to jump to
        }
    }

    private func postChanged() {
        NotificationCenter.default.post(name: .commentsDidChange, object: parent)
    }
}
