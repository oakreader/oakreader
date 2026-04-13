import Cocoa
import UniformTypeIdentifiers

class PDFDocumentController: NSDocumentController {
    weak var appState: AppState?

    override var defaultType: String? {
        UTType.pdf.identifier
    }

    override var documentClassNames: [String] {
        ["OakReaderDocument"]
    }

    override func documentClass(forType typeName: String) -> AnyClass? {
        OakReaderDocument.self
    }

    override func typeForContents(of url: URL) throws -> String {
        if url.pathExtension.lowercased() == "pdf" {
            return UTType.pdf.identifier
        }
        return try super.typeForContents(of: url)
    }

    // Disable macOS automatic document restoration on relaunch.
    // The app uses a custom tab architecture — restoring stale document
    // state causes "not a valid PDF" errors after rebuilds/updates.
    override func reopenDocument(for urlOrNil: URL?, withContentsOf contentsURL: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        // Silently skip — don't restore documents from previous session
        completionHandler(nil, false, nil)
    }

    // Route document opening through AppState to create tabs instead of windows
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        if let appState {
            // Check if already open
            if let existing = documents.first(where: { ($0 as? OakReaderDocument)?.fileURL == url }) as? OakReaderDocument {
                appState.switchToTab(appState.openTabs.first(where: { $0.document === existing })?.id ?? UUID())
                completionHandler(existing, false, nil)
                return
            }
            appState.openDocument(url: url)
            let doc = documents.last
            completionHandler(doc, false, nil)
        } else {
            super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
        }
    }
}
