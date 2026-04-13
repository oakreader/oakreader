import Foundation
import PDFKit
import OakReaderAI

/// Creates a Sendable PDFContextSnapshot from the current document state.
struct PDFContextProvider {
    private let textExtractor = TextExtractionService()

    func snapshot(
        from viewModel: DocumentViewModel,
        contextMode: ContextMode
    ) -> PDFContextSnapshot? {
        guard let pdfDoc = viewModel.pdfDocument else { return nil }

        let currentPageIndex = viewModel.state.currentPageIndex
        let currentPageText: String
        if let page = pdfDoc.page(at: currentPageIndex) {
            currentPageText = textExtractor.extractText(from: page)
        } else {
            currentPageText = ""
        }

        var fullText: String? = nil
        if contextMode == .fullDocument {
            let raw = textExtractor.extractAllText(from: pdfDoc)
            // Truncate to ~32K characters (~8K tokens)
            fullText = String(raw.prefix(32_000))
        }

        return PDFContextSnapshot(
            fileName: viewModel.fileName,
            pageCount: viewModel.pageCount,
            currentPageIndex: currentPageIndex,
            currentPageText: currentPageText,
            fullDocumentText: fullText,
            selectedText: viewModel.state.selectedText
        )
    }
}
