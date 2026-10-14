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
/// Writes follow Zotero's reader: the page is the part that must survive, so
/// a new page is written at once; movement within a page is debounced, because
/// scrolling reports a position many times a second. A write lost on a crash
/// costs an offset inside the page, never the page.
///
/// The cache also covers the in-memory `LibraryItem.lastPosition`, which goes
/// stale on purpose: reloading the library on every scroll would be absurd.
/// Main thread only, like the viewers that call it.
final class ReadingPositionStore {
    static let shared = ReadingPositionStore()

    private var cache: [UUID: Double] = [:]
    /// The last position sent to the catalog, per item. A new integer part
    /// against this one means a new page.
    private var written: [UUID: Double] = [:]
    private var pendingWrites: [UUID: DispatchWorkItem] = [:]
    /// Writes sent but not yet acknowledged, so a quit can wait for them.
    private var inFlight: [UUID: Task<Void, Never>] = [:]
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
        pendingWrites[itemID] = nil
        if written[itemID].map({ Int($0) != Int(position) }) ?? true {
            write(itemID)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.write(itemID) }
        pendingWrites[itemID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + writeDelay, execute: work)
    }

    /// Write every debounced position now and wait until the catalog has them.
    /// Called when a tab closes and before the app quits, so the last second
    /// of scrolling is not lost. Quit must await this: a write only started
    /// in `applicationWillTerminate` never runs, because the process exits first.
    func flush() async {
        for (itemID, work) in pendingWrites {
            work.cancel()
            write(itemID)
        }
        for task in Array(inFlight.values) {
            await task.value
        }
    }

    private func write(_ itemID: UUID) {
        pendingWrites[itemID] = nil
        guard let position = cache[itemID] else { return }
        written[itemID] = position
        let previous = inFlight[itemID]
        let task = Task {
            // In order per item, so an older position never lands last.
            await previous?.value
            await LibraryCatalog.update(id: itemID.uuidString, field: "lastPosition", number: position)
        }
        inFlight[itemID] = task
        Task { @MainActor [weak self] in
            await task.value
            if self?.inFlight[itemID] == task { self?.inFlight[itemID] = nil }
        }
    }
}
