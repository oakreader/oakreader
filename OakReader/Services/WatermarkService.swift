import Foundation
import PDFKit
import AppKit
import CoreGraphics
import CoreText

struct WatermarkService {

    func applyWatermark(
        _ config: WatermarkConfig,
        to document: PDFDocument
    ) throws {
        let tempURL = FileCoordination.temporaryURL(for: "watermarked_\(UUID().uuidString)")

        try PDFRewriter.rewriteDocument(document, to: tempURL) { page, pageIndex, context in
            guard config.pageRange.contains(pageIndex) else { return }
            let pageRect = page.bounds(for: .mediaBox)

            switch config.type {
            case .text(let text):
                drawTextWatermark(
                    text,
                    in: pageRect,
                    context: context,
                    config: config
                )
            case .image(let imageData):
                drawImageWatermark(
                    imageData,
                    in: pageRect,
                    context: context,
                    config: config
                )
            }
        }

        guard let watermarkedDoc = PDFDocument(url: tempURL) else {
            throw OakReaderError.watermarkFailed("Failed to create watermarked document.")
        }

        replaceDocumentPages(document, with: watermarkedDoc)
        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - Text Watermark

    private func drawTextWatermark(
        _ text: String,
        in pageRect: CGRect,
        context: CGContext,
        config: WatermarkConfig
    ) {
        context.saveGState()
        context.setAlpha(config.opacity)

        let font = NSFont(name: config.fontName, size: config.fontSize * config.scale)
            ?? NSFont.boldSystemFont(ofSize: config.fontSize * config.scale)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: config.color
        ]
        let attrString = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrString)
        let textBounds = CTLineGetBoundsWithOptions(line, [])

        let position = anchorPoint(
            for: config.position,
            in: pageRect,
            textSize: textBounds.size
        )

        context.translateBy(x: position.x, y: position.y)
        context.rotate(by: config.rotation * .pi / 180)
        context.translateBy(x: -textBounds.width / 2, y: -textBounds.height / 2)

        context.textPosition = .zero
        CTLineDraw(line, context)

        context.restoreGState()
    }

    // MARK: - Image Watermark

    private func drawImageWatermark(
        _ imageData: Data,
        in pageRect: CGRect,
        context: CGContext,
        config: WatermarkConfig
    ) {
        guard let nsImage = NSImage(data: imageData),
              let cgImage = nsImage.cgImage else { return }

        context.saveGState()
        context.setAlpha(config.opacity)

        let imgWidth = CGFloat(cgImage.width) * config.scale
        let imgHeight = CGFloat(cgImage.height) * config.scale

        let position = anchorPoint(
            for: config.position,
            in: pageRect,
            textSize: CGSize(width: imgWidth, height: imgHeight)
        )

        context.translateBy(x: position.x, y: position.y)
        context.rotate(by: config.rotation * .pi / 180)

        let drawRect = CGRect(
            x: -imgWidth / 2,
            y: -imgHeight / 2,
            width: imgWidth,
            height: imgHeight
        )
        context.draw(cgImage, in: drawRect)

        context.restoreGState()
    }

    // MARK: - Positioning

    private func anchorPoint(
        for position: WatermarkConfig.WatermarkPosition,
        in pageRect: CGRect,
        textSize: CGSize
    ) -> CGPoint {
        let margin: CGFloat = 36 // 0.5 inch
        switch position {
        case .center:
            return CGPoint(x: pageRect.midX, y: pageRect.midY)
        case .topLeft:
            return CGPoint(x: pageRect.minX + margin + textSize.width / 2, y: pageRect.maxY - margin - textSize.height / 2)
        case .topCenter:
            return CGPoint(x: pageRect.midX, y: pageRect.maxY - margin - textSize.height / 2)
        case .topRight:
            return CGPoint(x: pageRect.maxX - margin - textSize.width / 2, y: pageRect.maxY - margin - textSize.height / 2)
        case .bottomLeft:
            return CGPoint(x: pageRect.minX + margin + textSize.width / 2, y: pageRect.minY + margin + textSize.height / 2)
        case .bottomCenter:
            return CGPoint(x: pageRect.midX, y: pageRect.minY + margin + textSize.height / 2)
        case .bottomRight:
            return CGPoint(x: pageRect.maxX - margin - textSize.width / 2, y: pageRect.minY + margin + textSize.height / 2)
        }
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
