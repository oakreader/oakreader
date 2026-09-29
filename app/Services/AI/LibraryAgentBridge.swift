import Foundation

/// Keeps the library on screen honest about what the agent just did to it.
///
/// The `oak` tool runs a separate process against the same catalog. That is
/// the right shape — one tool with subcommands, so a new library capability is
/// a new subcommand rather than a new tool, a new schema and a new Swift file
/// — but it leaves this side unaware: the row lands, `LibraryStore` is never
/// told, and the agent announces a paper the grid does not show until the next
/// reload. So every mutating command ends here.
///
/// `@MainActor` because the store is, while agent tools are `Sendable` values
/// executed off it. Same shape as `LivePageBridge`, for the same reason.
@MainActor
final class LibraryAgentBridge {
    static let shared = LibraryAgentBridge()
    private init() {}

    private weak var store: LibraryStore?

    /// Called once by `AppState`, after the library is warm.
    func attach(store: LibraryStore) {
        self.store = store
    }

    /// Re-read the library after something outside the store wrote to it.
    func refresh() async {
        await store?.refresh()
    }
}
