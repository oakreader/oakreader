import Foundation

/// Backfills missing cover thumbnails for existing library items, off the scroll path.
///
/// The card grid is deliberately read-only — it never generates covers while scrolling (that
/// would spin a WKWebView per HTML card and, worse, call `store.updateCover` whose `invalidate()`
/// reloads the whole library per card). Instead this sweeper runs once when the grid appears:
///
/// - bounded concurrency (a few generations at a time, not one-per-item-on-screen),
/// - an `attempted` set so an item that yields no cover (e.g. a page with no `og:image`) is
///   never retried in a loop,
/// - it writes the cover file straight to disk and signals via `store.bumpCoverRevision()`
///   (which re-reads visible cards) rather than `invalidate()` (which refetches all items).
@MainActor
final class LibraryCoverSweeper {
    private let coverService: LibraryCoverService
    private var attempted = Set<UUID>()
    private var running = false
    /// The latest sweep request that arrived while a sweep was already in flight. The running
    /// sweep drains this when its current pass finishes, so it never gets dropped.
    private var pending: (items: [LibraryItem], store: LibraryStore)?

    private let maxConcurrent = 3
    private let bumpEvery = 12 // coalesce UI refreshes: re-read cards once per ~12 new covers

    init(coverService: LibraryCoverService) {
        self.coverService = coverService
    }

    /// Generate covers for any items in `items` that lack one. Cheap to call repeatedly — already
    /// attempted items are skipped. If a sweep is already in flight, the latest request is recorded
    /// and run as soon as the current pass finishes — so the progressive item-count growth during
    /// library load (43 → … → full set) always ends with a sweep over the *complete* set instead of
    /// dropping the larger set to a `running` guard. A pass always runs to completion (it is not
    /// tied to the caller's `.task` cancellation) — the work is bounded and covers persist.
    func sweep(items: [LibraryItem], store: LibraryStore) async {
        guard !running else { pending = (items, store); return }
        running = true
        defer { running = false }

        var next: (items: [LibraryItem], store: LibraryStore)? = (items, store)
        while let pass = next {
            pending = nil
            await runSweepPass(items: pass.items, store: pass.store)
            next = pending // a request that arrived during the pass coalesces into one more run
        }
    }

    private func runSweepPass(items: [LibraryItem], store: LibraryStore) async {
        // Cheap pre-filter (type + has a source), no disk I/O, no main-thread stat storm.
        let candidates = items.filter { Self.couldHaveCover($0) && !attempted.contains($0.id) }
        guard !candidates.isEmpty else { return }

        // Disk-existence check off the main thread (one stat per candidate).
        let targets = await Task.detached(priority: .utility) {
            candidates.filter { Self.needsCover($0) }
        }.value
        // Candidates that already have a usable cover are settled — mark them so we don't re-stat
        // them every sweep. Items that NEED a cover are marked attempted only once generation
        // SUCCEEDS (below), so a transient failure or a sweep cancelled mid-run (view dismissed)
        // leaves them retryable on the next grid appearance instead of stuck cover-less forever.
        let targetIDs = Set(targets.map(\.id))
        for candidate in candidates where !targetIDs.contains(candidate.id) {
            attempted.insert(candidate.id)
        }
        guard !targets.isEmpty else { return }

        var sinceBump = 0
        var index = 0
        while index < targets.count {
            // No `Task.isCancelled` check: a sweep is triggered by `.task(id: items.count)`, which
            // SwiftUI cancels the moment the count changes (progressive library load, or navigating
            // collections). Bailing here would abandon the work right when the *full* item set
            // finally arrived. The work is bounded (maxConcurrent, utility priority, `attempted`
            // dedup) and covers are useful regardless of the current view, so always run to completion.
            let batch = targets[index..<min(index + maxConcurrent, targets.count)]
            index += maxConcurrent

            let produced = await withTaskGroup(of: (UUID, Bool).self) { group in
                for item in batch { group.addTask { (item.id, await self.generateCover(for: item)) } }
                var count = 0
                for await (id, ok) in group where ok {
                    attempted.insert(id) // mark attempted only on success → failures retry next sweep
                    count += 1
                }
                return count
            }

            sinceBump += produced
            if sinceBump >= bumpEvery {
                store.bumpCoverRevision()
                sinceBump = 0
            }
        }
        if sinceBump > 0 { store.bumpCoverRevision() }
    }

    /// Generate one cover and write it to the attachment's `coverURL`. Returns whether a cover
    /// was produced. Does NOT touch the store (no `invalidate()`), so it can run hot in batches.
    private func generateCover(for item: LibraryItem) async -> Bool {
        guard let attachment = item.primaryAttachment else { return false }

        let data: Data?
        var isSyntheticFallback = false
        // Video items first — a YouTube/Bilibili source URL is the source of truth regardless of how
        // the attachment was stored. Many were saved as a printed-page "pdf" whose first-page render
        // is an ugly cropped web page (or fails → a typographic fallback); the real poster is always
        // the right cover. `generateLinkCover` short-circuits YouTube to its poster CDN and scrapes
        // Bilibili's og:image from the live page.
        let isVideo = item.sourceURL.map(Self.isVideoURL) ?? false
        if isVideo, let sourceURL = item.sourceURL {
            data = await coverService.generateLinkCover(for: sourceURL)
        } else {
            switch item.contentType {
            case .pdf:
                // Real first-page render — the most recognizable preview for a document. Fall back to
                // a synthetic typographic cover only when the page can't be rendered (encrypted/corrupt).
                if let render = await coverService.generateCover(for: item.fileURL) {
                    data = render
                } else {
                    isSyntheticFallback = true
                    data = await coverService.generatePaperCover(
                        title: item.title,
                        authors: Self.paperAuthors(item),
                        kicker: Self.paperKicker(item),
                        footer: Self.paperFooter(item)
                    )
                }
            case .html:
                data = await coverService.generateHTMLCover(for: item.fileURL, sourceURL: item.sourceURL)
            case .link:
                if let sourceURL = item.sourceURL {
                    data = await coverService.generateLinkCover(for: sourceURL)
                } else {
                    data = nil
                }
            default:
                data = nil
            }
        }
        guard let data else { return false }

        let url = attachment.coverURL
        // Positive marker: a PDF cover gets a `.render` sidecar ONLY when it's a real first-page
        // render — never for the video-poster override or a synthetic fallback — so `needsCover`
        // re-renders legacy covers exactly once.
        let renderMarkerURL = (item.contentType == .pdf && !isVideo) ? Self.renderMarkerURL(for: attachment) : nil
        let wroteRealRender = item.contentType == .pdf && !isVideo && !isSyntheticFallback
        // Stamp web/video covers with the og-fetch scheme marker so the one-time upgrade settles.
        let previewMarkerURL = (isVideo || item.contentType == .html || item.contentType == .link)
            ? Self.previewMarkerURL(for: attachment) : nil
        return await Task.detached(priority: .utility) {
            guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
            if let renderMarkerURL {
                if wroteRealRender {
                    try? Data().write(to: renderMarkerURL, options: .atomic)
                }
                try? FileManager.default.removeItem(at: Self.legacyPaperMarkerURL(for: attachment))
            }
            if let previewMarkerURL { try? Data().write(to: previewMarkerURL, options: .atomic) }
            return true
        }.value
    }

    // MARK: - Synthetic paper-cover metadata

    /// Authors line: prefer the item's stored author, else the CSL author list.
    nonisolated private static func paperAuthors(_ item: LibraryItem) -> String {
        item.author.isEmpty ? (item.referenceMetadata?.authorDisplayString ?? "") : item.author
    }

    /// Top-band kicker: the venue/journal, else "arXiv"/host for web PDFs, else "PDF".
    nonisolated private static func paperKicker(_ item: LibraryItem) -> String {
        if let journal = item.referenceMetadata?.journal, !journal.isEmpty { return journal }
        if let host = item.sourceURL?.host?.lowercased() {
            if host.contains("arxiv") { return "arXiv" }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return "PDF"
    }

    nonisolated private static func paperFooter(_ item: LibraryItem) -> String {
        item.referenceMetadata?.year.map(String.init) ?? ""
    }

    /// Type-level eligibility (no disk I/O). Markdown/audio have no derivable cover.
    nonisolated private static func couldHaveCover(_ item: LibraryItem) -> Bool {
        switch item.contentType {
        case .pdf, .html: return item.primaryAttachment != nil
        case .link: return item.sourceURL != nil
        default: return false
        }
    }

    /// Whether an item needs a cover (re)generated. A PDF needs one when it has no cover yet, or
    /// when its cover is NOT a real first-page render (no `.render` marker) — this upgrades every
    /// legacy synthetic cover, whether it came from the old import path or the old sweep path,
    /// exactly once. Other types just check for a cover file on disk.
    nonisolated private static func needsCover(_ item: LibraryItem) -> Bool {
        guard let attachment = item.primaryAttachment else { return false }
        let hasCover = FileManager.default.fileExists(atPath: attachment.coverURL.path)
        // Video items (any stored type): upgrade a legacy page-render/paper cover to the live poster
        // exactly once, gated on the og-fetch marker rather than the PDF `.render` marker.
        if let url = item.sourceURL, isVideoURL(url) {
            return !hasCover || !FileManager.default.fileExists(atPath: previewMarkerURL(for: attachment).path)
        }
        if item.contentType == .pdf {
            let isRealRender = FileManager.default.fileExists(atPath: renderMarkerURL(for: attachment).path)
            return !hasCover || !isRealRender
        }
        // html / link: regenerate when there's no cover, OR when the existing cover predates the
        // live og:image-fetch scheme (no marker) — this upgrades every legacy snapshot/favicon
        // cover to a real preview image (YouTube poster, Bilibili/site og:image) exactly once,
        // after which the marker keeps it settled.
        let hasScheme = FileManager.default.fileExists(atPath: previewMarkerURL(for: attachment).path)
        return !hasCover || !hasScheme
    }

    /// Whether a URL is a video we should cover with its poster rather than a page render: any
    /// YouTube watch/short/embed link, or a Bilibili `/video/` page. Used so a video saved as a
    /// printed-page "pdf" still gets its real thumbnail.
    nonisolated static func isVideoURL(_ url: URL) -> Bool {
        if LibraryCoverService.youTubeVideoID(url) != nil { return true }
        let host = url.host?.lowercased() ?? ""
        return host.contains("bilibili.com") && url.path.contains("/video/")
    }

    /// Sidecar marker proving a PDF's cover is a real first-page render (not a synthetic cover).
    nonisolated static func renderMarkerURL(for attachment: Attachment) -> URL {
        attachment.coverURL.appendingPathExtension("render")
    }

    /// Sidecar marker proving a web (html/link) cover was generated by the live og:image-fetch
    /// scheme. Absent on legacy snapshot/favicon covers, so `needsCover` upgrades them exactly once.
    nonisolated static func previewMarkerURL(for attachment: Attachment) -> URL {
        attachment.coverURL.appendingPathExtension("ogfetch")
    }

    /// Legacy `.paper` marker from the previous synthetic-cover scheme; cleaned up on re-render.
    nonisolated private static func legacyPaperMarkerURL(for attachment: Attachment) -> URL {
        attachment.coverURL.appendingPathExtension("paper")
    }
}
