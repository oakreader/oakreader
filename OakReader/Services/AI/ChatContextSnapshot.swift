import Foundation

/// Sendable snapshot of all context relevant to the AI chat session.
/// Built once before each message send, capturing value-type data from the view model layer.
struct ChatContextSnapshot: Sendable {
    // App-level context (always available)
    /// The selected collection, if any. Present for every selected collection
    /// (including smart / "All Items"); only `scopeId` is set when it is a real
    /// collection the agent should ground to.
    let activeCollection: ActiveCollection?
    let openTabTitles: [String]
    let activeTabTitle: String?
    /// Filesystem path of the active agent workspace folder (nil unless the
    /// full-page agent workspace is active). Source documents are CoW-mounted here.
    let agentWorkspacePath: String?

    struct ActiveCollection: Sendable {
        let name: String
        let itemCount: Int?
        let items: [CollectionItemSummary]
        /// Catalog id (UUID string) when this is a real collection to ground to
        /// (non-smart, non-"All Items"); `nil` otherwise. Doubles as the scope key
        /// used to physically restrict retrieval to its members.
        let scopeId: String?

        /// True when the agent should scope its retrieval to this collection.
        var isScopable: Bool { scopeId != nil }
    }

    struct CollectionItemSummary: Sendable {
        let title: String
        let author: String
        let citeKey: String?
    }

    // Document context (nil for library-scoped chat)
    let document: DocumentContext?

    struct DocumentContext: Sendable {
        // File info
        let fileName: String
        let filePath: String
        let contentType: ContentType
        /// True when a `.link`/`.audio` document has a real timeline (YouTube video,
        /// podcast) and should be cited by `?time=`. A live web page is also `.link`
        /// but has no timeline — it is cited like HTML (`?text=`/`?heading=`).
        let isTimelineMedia: Bool
        let pageCount: Int
        let currentPageIndex: Int
        let currentPageText: String
        let selectedText: String?

        // Library metadata
        let title: String
        let author: String
        let citeKey: String?
        let sourceURL: String?
        let tags: [String]
        let collectionNames: [String]

        // Reference metadata (CSL)
        let referenceType: String?
        let doi: String?
        let journal: String?
        let year: Int?
        let abstract: String?
        let volume: String?
        let issue: String?
        let pages: String?
    }
}
