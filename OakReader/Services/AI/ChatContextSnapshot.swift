import Foundation

/// Sendable snapshot of all context relevant to the AI chat session.
/// Built once before each message send, capturing value-type data from the view model layer.
struct ChatContextSnapshot: Sendable {
    // App-level context (always available)
    let activeCollectionName: String?
    let activeCollectionItemCount: Int?
    let openTabTitles: [String]
    let activeTabTitle: String?

    // Document context (nil for library-scoped chat)
    let document: DocumentContext?

    struct DocumentContext: Sendable {
        // File info
        let fileName: String
        let filePath: String
        let contentType: ContentType
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

        // Notes — title + absolute path so the AI can read them with ReadTool
        let notes: [(title: String, path: String)]
    }
}
