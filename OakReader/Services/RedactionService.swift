import Foundation
import PDFKit
import AppKit
import CoreGraphics

struct RedactionService {

    /// Applies redactions by RASTERIZING affected pages, which truly destroys
    /// the underlying content. Pages with redaction regions are converted to
    /// bitmap images and re-embedded as image-only PDF pages. This ensures
    /// no text, vector data, or metadata from the original content stream
    /// survives in the redacted areas.
    func applyRedactions(
        _ regions: [RedactionRegion],
        to document: PDFDocument
    ) throws {
        guard !regions.isEmpty else { return }

        // Group regions by page index
        var regionsByPage: [Int: [RedactionRegion]] = [:]
        for region in regions {
            regionsByPage[region.pageIndex, default: []].append(region)
        }

        // Process each affected page by rasterizing it
        for (pageIndex, pageRegions) in regionsByPage {
            guard let page = document.page(at: pageIndex) else { continue }

            let pageRect = page.bounds(for: .mediaBox)
            let dpi: CGFloat = 300
            let scale = dpi / 72.0
            let pixelWidth = Int(pageRect.width * scale)
            let pixelHeight = Int(pageRect.height * scale)

            // Safety: cap dimensions to prevent memory exhaustion
            guard pixelWidth > 0, pixelHeight > 0,
                  pixelWidth < 20000, pixelHeight < 20000 else {
                throw OakReaderError.redactionFailed("Page dimensions too large for safe rasterization.")
            }

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw OakReaderError.redactionFailed("Failed to create bitmap context for page \(pageIndex + 1).")
            }

            // Step 1: Render the ENTIRE page (with annotations) to a bitmap
            context.setFillColor(NSColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
            page.draw(with: .mediaBox, to: context)

            // Step 2: Draw redaction rectangles over the sensitive areas
            // This is now drawn on the BITMAP — there is no underlying content stream
            for region in pageRegions {
                // White-out first for clean coverage
                context.setFillColor(NSColor.white.cgColor)
                context.fill(region.bounds)
                // Black overlay (or user-specified color)
                context.setFillColor(region.overlayColor.cgColor)
                context.fill(region.bounds)

                if let overlayText = region.overlayText, !overlayText.isEmpty {
                    let font = NSFont.systemFont(ofSize: 8)
                    let textColor: NSColor = region.overlayColor == .black ? .white : .black
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: textColor
                    ]
                    let attrString = NSAttributedString(string: overlayText, attributes: attrs)
                    let line = CTLineCreateWithAttributedString(attrString)
                    context.textPosition = CGPoint(x: region.bounds.origin.x + 2, y: region.bounds.origin.y + 2)
                    CTLineDraw(line, context)
                }
            }

            // Step 3: Extract the bitmap as a CGImage
            guard let cgImage = context.makeImage() else {
                throw OakReaderError.redactionFailed("Failed to rasterize page \(pageIndex + 1).")
            }

            // Step 4: Create a new PDF page from the rasterized image
            // This page has NO text content stream — only a bitmap image
            let imageData = NSMutableData()
            var mediaBox = CGRect(origin: .zero, size: pageRect.size)
            guard let consumer = CGDataConsumer(data: imageData as CFMutableData),
                  let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                throw OakReaderError.redactionFailed("Failed to create PDF page from rasterized image.")
            }

            pdfContext.beginPDFPage(nil)
            pdfContext.draw(cgImage, in: CGRect(origin: .zero, size: pageRect.size))
            pdfContext.endPDFPage()
            pdfContext.closePDF()

            guard let newPDFDoc = PDFDocument(data: imageData as Data),
                  let newPage = newPDFDoc.page(at: 0) else {
                throw OakReaderError.redactionFailed("Failed to rebuild page \(pageIndex + 1) after redaction.")
            }

            // Step 5: Replace the original page with the rasterized one
            document.removePage(at: pageIndex)
            document.insert(newPage, at: pageIndex)
        }

        // Verify: attempt to extract text from redacted regions
        for (pageIndex, pageRegions) in regionsByPage {
            guard let page = document.page(at: pageIndex) else { continue }
            for region in pageRegions {
                if let selection = page.selection(for: region.bounds),
                   let text = selection.string,
                   !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Text still extractable — this should not happen with rasterization
                    // but check defensively
                    throw OakReaderError.redactionFailed(
                        "Verification failed: text still extractable from redacted region on page \(pageIndex + 1). " +
                        "Redaction was NOT applied safely."
                    )
                }
            }
        }
    }

    func markForRedaction(
        _ region: RedactionRegion,
        on document: PDFDocument
    ) {
        guard let page = document.page(at: region.pageIndex) else { return }
        let markAnnotation = region.createMarkAnnotation()
        page.addAnnotation(markAnnotation)
    }

    func removeRedactionMark(
        _ annotation: PDFAnnotation,
        from page: PDFPage
    ) {
        if annotation.contents == "Marked for Redaction" {
            page.removeAnnotation(annotation)
        }
    }
}
