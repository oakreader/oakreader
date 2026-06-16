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

    private let maxConcurrent = 3
    private let bumpEvery = 12 // coalesce UI refreshes: re-read cards once per ~12 new covers

    init(coverService: LibraryCoverService) {
        self.coverService = coverService
    }

    /// Generate covers for any items in `items` that lack one. Cheap to call repeatedly — already
    /// attempted items are skipped, and it no-ops if a sweep is already in flight. Cancels
    /// cooperatively when the calling `.task` is torn down (view disappears).
    func sweep(items: [LibraryItem], store: LibraryStore) async {
        guard !running else { return }
        running = true
        defer { running = false }

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
            if Task.isCancelled { break }
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
        guard let data else { return false }

        let url = attachment.coverURL
        // Positive marker: a PDF cover gets a `.render` sidecar ONLY when it's a real first-page
        // render. Everything else (legacy synthetic covers from the old import OR sweep paths, and
        // the synthetic fallback below) lacks it, so `needsCover` re-renders them exactly once.
        let renderMarkerURL = item.contentType == .pdf ? Self.renderMarkerURL(for: attachment) : nil
        let wroteRealRender = item.contentType == .pdf && !isSyntheticFallback
        return await Task.detached(priority: .utility) {
            guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
            if let renderMarkerURL {
                if wroteRealRender {
                    try? Data().write(to: renderMarkerURL, options: .atomic)
                }
                try? FileManager.default.removeItem(at: Self.legacyPaperMarkerURL(for: attachment))
            }
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
        if item.contentType == .pdf {
            let hasCover = FileManager.default.fileExists(atPath: attachment.coverURL.path)
            let isRealRender = FileManager.default.fileExists(atPath: renderMarkerURL(for: attachment).path)
            return !hasCover || !isRealRender
        }
        return !FileManager.default.fileExists(atPath: attachment.coverURL.path)
    }

    /// Sidecar marker proving a PDF's cover is a real first-page render (not a synthetic cover).
    nonisolated static func renderMarkerURL(for attachment: Attachment) -> URL {
        attachment.coverURL.appendingPathExtension("render")
    }

    /// Legacy `.paper` marker from the previous synthetic-cover scheme; cleaned up on re-render.
    nonisolated private static func legacyPaperMarkerURL(for attachment: Attachment) -> URL {
        attachment.coverURL.appendingPathExtension("paper")
    }
}
