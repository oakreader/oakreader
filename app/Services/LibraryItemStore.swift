import Foundation

extension LibraryStore {
    // MARK: - Fetch

    func findItem(byId id: UUID) -> LibraryItem? {
        loadedItems.first { $0.id == id }
    }

    func findItem(byStorageKey key: String) -> LibraryItem? {
        loadedItems.first { $0.storageKey == key }
    }

    func findItem(bySource source: String, sourceKey: String) -> LibraryItem? {
        loadedItems.first { $0.source == source && $0.sourceKey == sourceKey }
    }

    func findItem(byFileName fileName: String) -> LibraryItem? {
        loadedItems.first { item in item.attachments.contains { $0.fileName == fileName } }
    }

    func findItem(bySourceURL url: URL) -> LibraryItem? {
        loadedItems.first { $0.sourceURL == url }
    }

    /// Look in the bin. Separate because `findItem` deliberately does not.
    func findTrashedItem(byId id: UUID) -> LibraryItem? {
        loadedTrashedItems.first { $0.id == id }
    }

    /// Insert an item with its first attachment, and give it a cite key.
    ///
    /// Awaited rather than fired, unlike the other writes here. An import's
    /// next move is usually to save the item's metadata, and a citation row
    /// referencing an item that has not been written yet is a foreign-key
    /// failure — so the caller genuinely needs this one to have landed.
    ///
    /// The returned item carries the cite key the core assigned, which is why
    /// the insert answers with it rather than the caller re-reading.
    func insertItem(_ record: ItemRecord, attachment: AttachmentRecord) async -> LibraryItem? {
        var rec = record
        let att = Attachment(record: attachment, itemStorageKey: rec.storageKey)
        await LibraryCatalog.insert(CatalogItem(record: rec, attachments: [attachment]))
        rec.citeKey = await ReferenceCatalog.assignCiteKey(forItemId: rec.id)
        invalidate()
        return LibraryItem(
            record: rec,
            attachments: [att],
            coverImageData: Self.loadCoverData(attachment: att))
    }

    /// Delete an item permanently: its rows, and the files they pointed at.
    ///
    /// Two owners, in order. The core drops the row and everything the schema
    /// cascades from it — attachments, annotations, memberships, citations,
    /// conversation rows. The shell then deletes what lives on disk: the
    /// document's storage directory and each conversation's JSONL transcript.
    ///
    /// The conversation ids have to be read *before* the row goes, because the
    /// cascade takes them with it and the transcripts are named after them.
    func removeItem(_ item: LibraryItem) {
        removeItems([item])
    }

    func removeItems(_ items: [LibraryItem]) {
        guard !items.isEmpty else { return }
        Task {
            var transcripts: [UUID] = []
            for item in items {
                let conversations = await ConversationService()
                    .fetchSessions(forItemId: item.id.uuidString)
                transcripts.append(contentsOf: conversations.map(\.id))
            }

            await LibraryCatalog.remove(ids: items.map { $0.id.uuidString })

            // Files, now that nothing references them.
            for id in transcripts {
                try? FileManager.default.removeItem(at: CatalogDatabase.chatFileURL(sessionId: id))
                try? FileManager.default.removeItem(
                    at: CatalogDatabase.chatAttachmentDirectory(sessionId: id))
            }
            for item in items {
                try? FileManager.default.removeItem(
                    at: CatalogDatabase.documentDirectory(storageKey: item.storageKey))
            }

            await MainActor.run { self.invalidate() }
        }
    }

    /// These stay synchronous: every caller is a UI action, and the write is
    /// fire-and-forget followed by `invalidate()`, which reloads behind itself.
    /// Waiting on the round trip would stall a click to confirm something the
    /// interface has already shown.

    func markOpened(_ item: LibraryItem) {
        update(item, field: "lastOpenedAt", string: Date().iso8601String)
    }

    func updateTitle(_ item: LibraryItem, title: String) {
        update(item, field: "title", string: title)
    }

    func updateProcessingStatus(_ item: LibraryItem, status: ProcessingStatus) {
        update(item, field: "processingStatus", string: status.rawValue)
    }

    func updateLastPosition(_ item: LibraryItem, position: Double) {
        // Deliberately no invalidate: scroll position changes constantly and
        // reloading the library on every one would be absurd. Nothing displays
        // it, so the in-memory copy going stale costs nothing.
        Task { await LibraryCatalog.update(id: item.id.uuidString, field: "lastPosition", number: position) }
    }

    private func update(_ item: LibraryItem, field: String, string: String) {
        Task {
            await LibraryCatalog.update(id: item.id.uuidString, field: field, string: string)
            await MainActor.run { self.invalidate() }
        }
    }

    func updateCover(_ item: LibraryItem, imageData: Data) {
        guard let primary = item.primaryAttachment else { return }
        let coverURL = primary.coverURL
        do {
            try imageData.write(to: coverURL, options: .atomic)
            // Stamp web covers with the og-fetch scheme marker so the sweeper's one-time upgrade
            // doesn't needlessly re-generate a cover the current build just wrote.
            if item.contentType == .html || item.contentType == .link {
                try? Data().write(to: LibraryCoverSweeper.previewMarkerURL(for: primary), options: .atomic)
            }
            invalidate()
        } catch {
            Log.error(Log.store, "updateCover failed: \(error)")
        }
    }

    // MARK: - Merge Duplicates

    /// Merge duplicates into a keeper: rows in the core, files here.
    ///
    /// The split follows the ownership line everywhere else in this store. The
    /// core re-parents attachments, memberships, property values, annotations,
    /// conversations and citations in one transaction and deletes the
    /// duplicates; the shell moves the attachment files onto the keeper and
    /// removes what is left behind.
    ///
    /// Files move first, deliberately. If the app dies between the two halves,
    /// a copied file with its row still on the duplicate is recoverable; a
    /// re-parented row pointing at a file that was never moved is not.
    func mergeItems(keeper: LibraryItem, duplicates: [LibraryItem]) {
        let merging = duplicates.filter { $0.id != keeper.id }
        guard !merging.isEmpty else { return }

        for duplicate in merging {
            moveAttachmentFiles(from: duplicate, to: keeper)
        }

        Task { @MainActor in
            await LibraryCatalog.merge(
                keeperId: keeper.id.uuidString,
                duplicateIds: merging.map(\.id.uuidString))

            let fileManager = FileManager.default
            for duplicate in merging {
                try? fileManager.removeItem(
                    at: CatalogDatabase.documentDirectory(storageKey: duplicate.storageKey))
            }
            self.invalidate()
        }
    }

    /// Move a duplicate's attachment files into the keeper's directory,
    /// leaving any name that is already taken alone.
    private func moveAttachmentFiles(from duplicate: LibraryItem, to keeper: LibraryItem) {
        let fileManager = FileManager.default
        let source = CatalogDatabase.documentDirectory(storageKey: duplicate.storageKey)
            .appendingPathComponent("attachments", isDirectory: true)
        guard fileManager.fileExists(atPath: source.path) else { return }

        let destination = CatalogDatabase.documentDirectory(storageKey: keeper.storageKey)
            .appendingPathComponent("attachments", isDirectory: true)
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            Log.error(Log.store, "mergeItems: cannot create \(destination.path): \(error)")
            return
        }

        let children = (try? fileManager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        for child in children {
            let target = destination.appendingPathComponent(child.lastPathComponent)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            try? fileManager.moveItem(at: child, to: target)
        }
    }

    // MARK: - Soft Delete (Bin)

    func trashItem(_ item: LibraryItem) { trashItems([item]) }

    func trashItems(_ items: [LibraryItem]) {
        setTrashed(items, trashed: true)
    }

    func restoreItem(_ item: LibraryItem) { restoreItems([item]) }

    func restoreItems(_ items: [LibraryItem]) {
        setTrashed(items, trashed: false)
    }

    private func setTrashed(_ items: [LibraryItem], trashed: Bool) {
        guard !items.isEmpty else { return }
        let ids = items.map { $0.id.uuidString }
        Task {
            await LibraryCatalog.setTrashed(ids: ids, trashed: trashed)
            await MainActor.run { self.invalidate() }
        }
    }

    /// One call rather than a loop: the core deletes the batch in a
    /// transaction, so an interrupted empty cannot leave the bin half-cleared.
    func emptyBin() {
        removeItems(loadedTrashedItems)
    }

    // MARK: - Cover helpers

    private static func loadCoverData(attachment: Attachment) -> Data? {
        let url = attachment.coverURL
        return try? Data(contentsOf: url)
    }
}
