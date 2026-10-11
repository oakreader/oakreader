import Foundation

/// Where the reader left each library document, so reopening it lands there
/// instead of on the first page.
///
/// The position lives in `items.last_position`, one number per item, whose
/// meaning depends on the content type:
/// - PDF: page index plus the fraction down that page (`12.37` = page 13, 37%
///   of the way down). The integer part alone is enough for a page-level restore.
/// - HTML snapshot and Markdown: the scroll fraction of the whole document, 0…1.
///
/// Scrolling reports a position many times a second, so writes are debounced.
/// The cache also covers the in-memory `LibraryItem.lastPosition`, which goes
/// stale on purpose: reloading the library on every scroll would be absurd.
/// Main thread only, like the viewers that call it.
final class ReadingPositionStore {
    static let shared = ReadingPositionStore()

    private var cache: [UUID: Double] = [:]
    private var pendingWrites: [UUID: DispatchWorkItem] = [:]
    private let writeDelay: TimeInterval = 1.0

    private init() {}

    /// The newest known position for `item`, or `nil` when it was never read.
    func position(for item: LibraryItem) -> Double? {
        cache[item.id] ?? item.lastPosition
    }

    func record(_ position: Double, for itemID: UUID) {
        guard position.isFinite, position >= 0, cache[itemID] != position else { return }
        cache[itemID] = position
        pendingWrites[itemID]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(itemID) }
        pendingWrites[itemID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + writeDelay, execute: work)
    }

    /// Write every debounced position now. Called when a tab closes and when
    /// the app quits, so the last second of scrolling is not lost.
    func flush() {
        for (itemID, work) in pendingWrites {
            work.cancel()
            write(itemID)
        }
    }

    private func write(_ itemID: UUID) {
        pendingWrites[itemID] = nil
        guard let position = cache[itemID] else { return }
        Task { await LibraryCatalog.update(id: itemID.uuidString, field: "lastPosition", number: position) }
    }
}
