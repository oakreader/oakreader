import CoreGraphics
import PDFKit

extension CGPDFDocument {
    var pageCount: Int { numberOfPages }

    func allPageRects() -> [CGRect] {
        (1...numberOfPages).compactMap { pageNumber in
            guard let page = page(at: pageNumber) else { return nil }
            return page.getBoxRect(.mediaBox)
        }
    }
}

struct PDFRewriter {
    static func rewriteDocument(
        _ source: PDFDocument,
        to outputURL: URL,
        options: [String: Any] = [:],
        pageTransform: ((PDFPage, Int, CGContext) -> Void)? = nil
    ) throws {
        guard source.pageCount > 0 else {
            throw OakReaderError.invalidPDF
        }

        guard let firstPage = source.page(at: 0) else {
            throw OakReaderError.invalidPDF
        }
        var mediaBox = firstPage.bounds(for: .mediaBox)

        guard let context = CGContext(outputURL as CFURL, mediaBox: &mediaBox, options as CFDictionary) else {
            throw OakReaderError.fileWriteFailed(outputURL, underlying: nil)
        }

        for i in 0..<source.pageCount {
            guard let page = source.page(at: i) else { continue }
            var pageBox = page.bounds(for: .mediaBox)

            let pageInfo: [String: Any] = [
                kCGPDFContextMediaBox as String: NSValue(rect: pageBox)
            ]
            context.beginPDFPage(pageInfo as CFDictionary)

            // Draw original page content
            context.saveGState()
            if let cgPage = page.pageRef {
                context.translateBy(x: -pageBox.origin.x, y: -pageBox.origin.y)
                context.drawPDFPage(cgPage)
            }
            context.restoreGState()

            // Apply any custom transform
            pageTransform?(page, i, context)

            context.endPDFPage()
        }

        context.closePDF()
    }

    static func rewriteWithSecurity(
        _ source: PDFDocument,
        to outputURL: URL,
        settings: SecuritySettings
    ) throws {
        try rewriteDocument(source, to: outputURL, options: settings.contextOptions)
    }
}
