import Foundation

extension ImportService {

    struct XBookmarksSyncResult {
        var imported: Int = 0
        var skipped: Int = 0
        var total: Int = 0
    }

    /// Sync X bookmarks using the provided Bearer Token.
    /// Paginates up to 8 pages (800 bookmarks max). Deduplicates by source/sourceKey.
    func syncXBookmarks(bearerToken: String) async throws -> XBookmarksSyncResult {
        // Look up user ID if not cached
        var userId = Preferences.shared.xUserId
        if userId == nil {
            let user = try await XBookmarksAPIClient.lookupUser(bearerToken: bearerToken)
            userId = user.id
            Preferences.shared.xUserId = user.id
        }
        guard let uid = userId else { throw SyncError.authenticationFailed }

        var result = XBookmarksSyncResult()
        var paginationToken: String?
        let maxPages = 8

        for _ in 0..<maxPages {
            let response = try await XBookmarksAPIClient.fetchBookmarks(
                bearerToken: bearerToken,
                userId: uid,
                paginationToken: paginationToken
            )

            guard let tweets = response.data, !tweets.isEmpty else { break }

            for tweet in tweets {
                result.total += 1

                // Dedup by source + sourceKey
                if store.findItem(bySource: "x_bookmarks", sourceKey: tweet.id) != nil {
                    result.skipped += 1
                    continue
                }

                importXBookmark(tweet: tweet)
                result.imported += 1
            }

            // Check for next page
            guard let nextToken = response.meta?.nextToken else { break }
            paginationToken = nextToken
        }

        return result
    }

    /// Re-sync all existing X Bookmarks: regenerate embed.html and context.md from stored metadata.
    func resyncXBookmarks() -> XBookmarksSyncResult {
        let existingItems = store.items.filter { $0.source == "x_bookmarks" }
        var result = XBookmarksSyncResult()
        result.total = existingItems.count

        for item in existingItems {
            guard let att = item.primaryAttachment else {
                result.skipped += 1
                continue
            }

            let attDir = CatalogDatabase.attachmentDirectory(
                itemStorageKey: item.storageKey,
                attachmentStorageKey: att.storageKey
            )

            // Read existing metadata.json to rebuild embed
            let metadataURL = attDir.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(MediaMetadata.self, from: data) else {
                result.skipped += 1
                continue
            }

            // Regenerate embed.html
            let embedHTML = Self.generateTweetEmbedHTML(metadata: metadata)
            try? embedHTML.write(
                to: attDir.appendingPathComponent("embed.html"),
                atomically: true, encoding: .utf8
            )

            // Regenerate context.md
            let tweetText = metadata.description ?? ""
            if !tweetText.isEmpty {
                let contextMd = """
                # \(metadata.author)

                \(tweetText)

                ---
                [View on X](\(metadata.sourceURL.absoluteString))\(metadata.publishedAt.map { " · \($0)" } ?? "")
                """
                try? contextMd.write(
                    to: attDir.appendingPathComponent("context.md"),
                    atomically: true, encoding: .utf8
                )
            }

            result.imported += 1
        }

        return result
    }

    /// Import a single X bookmark as an embed item.
    private func importXBookmark(tweet: XBookmarksAPIClient.BookmarksResponse.Tweet) {
        let tweetURL = URL(string: "https://x.com/i/status/\(tweet.id)")!
        let authorHandle = tweet.authorId ?? "unknown"
        let title = "@\(authorHandle)"

        // Truncate tweet text for display title
        let displayTitle: String
        if tweet.text.count > 80 {
            displayTitle = String(tweet.text.prefix(80)) + "…"
        } else {
            displayTitle = tweet.text
        }

        let metadata = MediaMetadata(
            title: displayTitle,
            author: title,
            sourceURL: tweetURL,
            duration: nil,
            thumbnailURL: nil,
            publishedAt: tweet.createdAt,
            description: tweet.text,
            embedType: "twitter"
        )

        let docId = UUID()
        let attId = UUID()
        let itemStorageKey = CatalogDatabase.generateStorageKey()
        let attStorageKey = CatalogDatabase.generateStorageKey()
        let docDir = CatalogDatabase.documentDirectory(storageKey: itemStorageKey)
        let attDir = CatalogDatabase.attachmentDirectory(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)

        do {
            try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: attDir, withIntermediateDirectories: true)

            // Write metadata.json
            let metadataURL = CatalogDatabase.attachmentMetadataURL(itemStorageKey: itemStorageKey, attachmentStorageKey: attStorageKey)
            let encoded = try JSONEncoder().encode(metadata)
            try encoded.write(to: metadataURL, options: .atomic)

            // Generate embed.html using existing tweet card generator
            let embedHTML = Self.generateTweetEmbedHTML(metadata: metadata)
            let embedHTMLURL = attDir.appendingPathComponent("embed.html")
            try embedHTML.write(to: embedHTMLURL, atomically: true, encoding: .utf8)

            // Write context.md — tweet text as markdown for reading and search
            let contextMd = """
            # \(title)

            \(tweet.text)

            ---
            [View on X](\(tweetURL.absoluteString))\(tweet.createdAt.map { " · \($0)" } ?? "")
            """
            let contextURL = attDir.appendingPathComponent("context.md")
            try contextMd.write(to: contextURL, atomically: true, encoding: .utf8)
        } catch {
            Log.error(Log.importer, "Failed to import X bookmark \(tweet.id): \(error)")
            try? FileManager.default.removeItem(at: docDir)
            return
        }

        let now = Date().iso8601String
        let itemRecord = ItemRecord(
            id: docId.uuidString,
            userId: localUserId,
            storageKey: itemStorageKey,
            title: displayTitle,
            author: title,
            lastOpenedAt: nil,
            syncStatus: SyncStatus.local.rawValue,
            createdAt: now,
            updatedAt: now,
            source: "x_bookmarks",
            sourceKey: tweet.id
        )

        let attRecord = AttachmentRecord(
            id: attId.uuidString,
            itemId: docId.uuidString,
            storageKey: attStorageKey,
            fileName: "metadata.json",
            contentType: ContentType.video.rawValue,
            linkMode: LinkMode.linkedURL.rawValue,
            sourceURL: tweetURL.absoluteString,
            fileSize: 0,
            pageCount: 0,
            isPrimary: true,
            createdAt: now,
            updatedAt: now
        )

        guard let item = store.insertItem(itemRecord, attachment: attRecord) else {
            try? FileManager.default.removeItem(at: docDir)
            return
        }

        // Auto-create CSL reference
        var csl = CSLItem(type: "post")
        csl.title = displayTitle
        csl.author = [CSLName(family: title, given: nil)]
        csl.URL = tweetURL.absoluteString
        try? referenceService.saveMetadata(csl, forItemId: docId.uuidString)
        store.invalidate()

        // Semantic index
        if let service = semanticIndexService {
            Task {
                await service.indexItem(
                    itemId: docId.uuidString,
                    contentType: ContentType.video.rawValue,
                    storageKey: itemStorageKey,
                    attStorageKey: attStorageKey,
                    fileName: "metadata.json"
                )
            }
        }
    }
}
