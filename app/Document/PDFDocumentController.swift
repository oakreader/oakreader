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
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return UTType.pdf.identifier
        }
        return try super.typeForContents(of: url)
    }

    // Route document opening through AppState to import and create tabs
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
