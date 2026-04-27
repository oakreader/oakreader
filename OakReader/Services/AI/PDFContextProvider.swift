import Foundation
import PDFKit
import AppKit
import OakReaderAI

/// Creates a Sendable PDFContextSnapshot from the current document state.
struct PDFContextProvider {
    private let textExtractor = TextExtractionService()

    func snapshot(
        from viewModel: DocumentViewModel,
        contextMode: ContextMode
    ) -> PDFContextSnapshot? {
        switch viewModel.documentType {
        case .pdf:
            return pdfSnapshot(from: viewModel, contextMode: contextMode)
        case .webSnapshot:
            return webSnapshotSnapshot(from: viewModel, contextMode: contextMode)
        case .youtubeVideo, .podcast:
            return mediaSnapshot(from: viewModel, contextMode: contextMode)
        }
    }

    // MARK: - PDF

    private func pdfSnapshot(
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

    // MARK: - Web Snapshot

    private func webSnapshotSnapshot(
        from viewModel: DocumentViewModel,
        contextMode: ContextMode
    ) -> PDFContextSnapshot? {
        guard let snapshot = viewModel.webSnapshot else { return nil }

        let htmlText = extractTextFromHTML(url: snapshot.htmlURL)
        let truncated = String(htmlText.prefix(32_000))

        return PDFContextSnapshot(
            fileName: viewModel.fileName,
            pageCount: 1,
            currentPageIndex: 0,
            currentPageText: truncated,
            fullDocumentText: contextMode == .fullDocument ? truncated : nil,
            selectedText: viewModel.state.selectedText
        )
    }

    // MARK: - Media (YouTube / Podcast)

    private func mediaSnapshot(
        from viewModel: DocumentViewModel,
        contextMode: ContextMode
    ) -> PDFContextSnapshot? {
        guard let media = viewModel.mediaDocument else { return nil }

        // Read transcript, fall back to description
        var text = ""
        if let transcriptURL = media.transcriptURL,
           let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8) {
            text = transcript
        } else if let description = media.metadata.description {
            text = description
        }
        let truncated = String(text.prefix(32_000))

        return PDFContextSnapshot(
            fileName: media.metadata.title,
            pageCount: 1,
            currentPageIndex: 0,
            currentPageText: truncated,
            fullDocumentText: contextMode == .fullDocument ? truncated : nil,
            selectedText: viewModel.state.selectedText
        )
    }

    /// Extract plain text from an HTML file by stripping tags via NSAttributedString.
    private func extractTextFromHTML(url: URL) -> String {
        guard let htmlData = try? Data(contentsOf: url) else { return "" }
        guard let attrString = NSAttributedString(
            html: htmlData,
            baseURL: url.deletingLastPathComponent(),
            documentAttributes: nil
        ) else { return "" }
        return attrString.string
    }
}
