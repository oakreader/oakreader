import Foundation
import PDFKit
import AppKit

actor LibraryCoverService {
    private let renderingService = PDFRenderingService()
    private let maxDimension: CGFloat = 320

    func generateCover(for url: URL) async -> Data? {
        guard let pdfDoc = PDFDocument(url: url),
              let firstPage = pdfDoc.page(at: 0) else { return nil }

        let thumbnail = renderingService.renderThumbnail(firstPage, maxDimension: maxDimension)
        return thumbnail.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        }
    }

    func generateCover(for item: PDFLibraryItem) async -> Data? {
        guard let url = item.resolveFileURL() else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        return await generateCover(for: url)
    }
}
