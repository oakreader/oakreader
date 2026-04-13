import Foundation
import PDFKit
import AppKit
import CoreGraphics
import CoreText

struct HeaderFooterService {

    func applyHeaderFooter(
        _ config: HeaderFooterConfig,
        to document: PDFDocument
    ) throws {
        let tempURL = FileCoordination.temporaryURL(for: "hf_\(UUID().uuidString)")
        let totalPages = document.pageCount

        try PDFRewriter.rewriteDocument(document, to: tempURL) { page, pageIndex, context in
            guard config.pageRange.contains(pageIndex) else { return }
            let pageRect = page.bounds(for: .mediaBox)
            let margins = config.margins

            let font = NSFont(name: config.fontName, size: config.fontSize)
                ?? NSFont.systemFont(ofSize: config.fontSize)

            // Header
            let headerY = pageRect.maxY - margins.top

            let headerLeftText = config.resolvedText(config.headerLeft, pageIndex: pageIndex, totalPages: totalPages)
            if !headerLeftText.isEmpty {
                drawAlignedText(
                    headerLeftText,
                    at: CGPoint(x: pageRect.minX + margins.left, y: headerY),
                    alignment: .left,
                    font: font,
                    color: config.color,
                    context: context
                )
            }

            let headerCenterText = config.resolvedText(config.headerCenter, pageIndex: pageIndex, totalPages: totalPages)
            if !headerCenterText.isEmpty {
                drawAlignedText(
                    headerCenterText,
                    at: CGPoint(x: pageRect.midX, y: headerY),
                    alignment: .center,
                    font: font,
                    color: config.color,
                    context: context
                )
            }

            let headerRightText = config.resolvedText(config.headerRight, pageIndex: pageIndex, totalPages: totalPages)
            if !headerRightText.isEmpty {
                drawAlignedText(
                    headerRightText,
                    at: CGPoint(x: pageRect.maxX - margins.right, y: headerY),
                    alignment: .right,
                    font: font,
                    color: config.color,
                    context: context
                )
            }

            // Footer
            let footerY = pageRect.minY + margins.bottom

            let footerLeftText = config.resolvedText(config.footerLeft, pageIndex: pageIndex, totalPages: totalPages)
            if !footerLeftText.isEmpty {
                drawAlignedText(
                    footerLeftText,
                    at: CGPoint(x: pageRect.minX + margins.left, y: footerY),
                    alignment: .left,
                    font: font,
                    color: config.color,
                    context: context
                )
            }

            let footerCenterText = config.resolvedText(config.footerCenter, pageIndex: pageIndex, totalPages: totalPages)
            if !footerCenterText.isEmpty {
                drawAlignedText(
                    footerCenterText,
                    at: CGPoint(x: pageRect.midX, y: footerY),
                    alignment: .center,
                    font: font,
                    color: config.color,
                    context: context
                )
            }

            let footerRightText = config.resolvedText(config.footerRight, pageIndex: pageIndex, totalPages: totalPages)
            if !footerRightText.isEmpty {
                drawAlignedText(
                    footerRightText,
                    at: CGPoint(x: pageRect.maxX - margins.right, y: footerY),
                    alignment: .right,
                    font: font,
                    color: config.color,
                    context: context
                )
            }
        }

        guard let resultDoc = PDFDocument(url: tempURL) else {
            throw OakReaderError.exportFailed("Failed to create document with headers/footers.")
        }

        replaceDocumentPages(document, with: resultDoc)
        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - Text Drawing

    private enum TextAlignment {
        case left, center, right
    }

    private func drawAlignedText(
        _ text: String,
        at point: CGPoint,
        alignment: TextAlignment,
        font: NSFont,
        color: NSColor,
        context: CGContext
    ) {
        context.saveGState()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attrString = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrString)
        let textBounds = CTLineGetBoundsWithOptions(line, [])

        var x: CGFloat
        switch alignment {
        case .left:
            x = point.x
        case .center:
            x = point.x - textBounds.width / 2
        case .right:
            x = point.x - textBounds.width
        }

        context.textPosition = CGPoint(x: x, y: point.y)
        CTLineDraw(line, context)

        context.restoreGState()
    }

    // MARK: - Private

    private func replaceDocumentPages(_ target: PDFDocument, with source: PDFDocument) {
        while target.pageCount > 0 {
            target.removePage(at: 0)
        }
        for i in 0..<source.pageCount {
            guard let page = source.page(at: i) else { continue }
            if let copiedPage = page.copy() as? PDFPage {
                target.insert(copiedPage, at: target.pageCount)
            }
        }
    }
}
