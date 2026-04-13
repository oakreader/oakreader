import Foundation
import PDFKit
import AppKit

@Observable
class WatermarkViewModel {
    weak var parent: DocumentViewModel?

    var config: WatermarkConfig = WatermarkConfig()
    var isPreviewVisible: Bool = false
    var isApplying: Bool = false
    var customText: String = "CONFIDENTIAL"
    var imageData: Data?

    init(parent: DocumentViewModel) {
        self.parent = parent
    }

    private var pdfDocument: PDFDocument? { parent?.pdfDocument }

    // MARK: - Configuration

    func setTextWatermark(_ text: String) {
        customText = text
        config.type = .text(text)
    }

    func setImageWatermark(from image: NSImage) {
        guard let data = image.tiffRepresentation else { return }
        imageData = data
        config.type = .image(data)
    }

    func setOpacity(_ value: CGFloat) {
        config.opacity = max(0.01, min(1.0, value))
    }

    func setRotation(_ degrees: CGFloat) {
        config.rotation = degrees
    }

    func setPosition(_ position: WatermarkConfig.WatermarkPosition) {
        config.position = position
    }

    func setScale(_ scale: CGFloat) {
        config.scale = max(0.1, min(5.0, scale))
    }

    func setFontSize(_ size: CGFloat) {
        config.fontSize = max(8, min(200, size))
    }

    func setFontName(_ name: String) {
        config.fontName = name
    }

    func setColor(_ color: NSColor) {
        config.color = color
    }

    func setAboveContent(_ above: Bool) {
        config.isAboveContent = above
    }

    func setPageRange(_ range: PageRange) {
        config.pageRange = range
    }

    // MARK: - Preview

    func togglePreview() {
        isPreviewVisible.toggle()
    }

    func generatePreview(for pageIndex: Int) -> NSImage? {
        guard let doc = pdfDocument,
              let page = doc.page(at: pageIndex) else { return nil }

        let pageRect = page.bounds(for: .mediaBox)
        let scale: CGFloat = 1.0

        let image = NSImage(size: CGSize(width: pageRect.width * scale, height: pageRect.height * scale))
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }

        // Draw the page
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)

        // Draw the watermark preview
        drawWatermark(in: context, pageRect: pageRect)

        image.unlockFocus()
        return image
    }

    // MARK: - Apply

    func apply(to document: PDFDocument? = nil) async {
        let targetDoc = document ?? pdfDocument
        guard let doc = targetDoc else { return }

        await MainActor.run {
            isApplying = true
        }

        let tempURL = FileCoordination.temporaryURL()
        let localConfig = config

        do {
            try PDFRewriter.rewriteDocument(doc, to: tempURL) { [weak self] page, pageIndex, context in
                guard localConfig.pageRange.contains(pageIndex) else { return }
                self?.drawWatermark(in: context, pageRect: page.bounds(for: .mediaBox))
            }

            // Replace pages in the original document with watermarked versions
            guard let watermarkedDoc = PDFDocument(url: tempURL) else {
                throw OakReaderError.watermarkFailed("Failed to load watermarked document")
            }

            await MainActor.run {
                let pageCount = doc.pageCount
                for i in 0..<min(pageCount, watermarkedDoc.pageCount) {
                    guard let newPage = watermarkedDoc.page(at: i),
                          let copied = newPage.copy() as? PDFPage else { continue }
                    doc.removePage(at: i)
                    doc.insert(copied, at: i)
                }

                isApplying = false
                if document == nil {
                    parent?.markDocumentEdited()
                }
            }

            try? FileManager.default.removeItem(at: tempURL)

        } catch {
            await MainActor.run {
                isApplying = false
                parent?.state.presentError("Watermark failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Drawing

    private func drawWatermark(in context: CGContext, pageRect: CGRect) {
        switch config.type {
        case .text(let text):
            let font = NSFont(name: config.fontName, size: config.fontSize)
                ?? NSFont.systemFont(ofSize: config.fontSize)

            // Position the watermark based on the position setting
            let targetRect = positionedRect(in: pageRect, font: font, text: text)

            context.saveGState()
            context.setAlpha(config.opacity)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: config.color
            ]
            let attrString = NSAttributedString(string: text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrString)
            let textBounds = CTLineGetBoundsWithOptions(line, [])

            // Move to position center and rotate
            context.translateBy(x: targetRect.midX, y: targetRect.midY)
            context.rotate(by: config.rotation * .pi / 180)
            context.translateBy(x: -textBounds.width / 2, y: -textBounds.height / 2)

            context.textPosition = .zero
            CTLineDraw(line, context)

            context.restoreGState()

        case .image(let data):
            guard let nsImage = NSImage(data: data),
                  let cgImage = nsImage.cgImage else { return }

            let imgWidth = CGFloat(cgImage.width) * config.scale
            let imgHeight = CGFloat(cgImage.height) * config.scale

            let targetPoint = positionedPoint(in: pageRect, size: CGSize(width: imgWidth, height: imgHeight))

            context.saveGState()
            context.setAlpha(config.opacity)
            context.draw(cgImage, in: CGRect(x: targetPoint.x, y: targetPoint.y, width: imgWidth, height: imgHeight))
            context.restoreGState()
        }
    }

    private func positionedRect(in pageRect: CGRect, font: NSFont, text: String) -> CGRect {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attrs)

        let point = positionedPoint(in: pageRect, size: textSize)
        return CGRect(origin: point, size: textSize)
    }

    private func positionedPoint(in pageRect: CGRect, size: CGSize) -> CGPoint {
        let margin: CGFloat = 36

        switch config.position {
        case .center:
            return CGPoint(x: pageRect.midX - size.width / 2, y: pageRect.midY - size.height / 2)
        case .topLeft:
            return CGPoint(x: margin, y: pageRect.maxY - margin - size.height)
        case .topCenter:
            return CGPoint(x: pageRect.midX - size.width / 2, y: pageRect.maxY - margin - size.height)
        case .topRight:
            return CGPoint(x: pageRect.maxX - margin - size.width, y: pageRect.maxY - margin - size.height)
        case .bottomLeft:
            return CGPoint(x: margin, y: margin)
        case .bottomCenter:
            return CGPoint(x: pageRect.midX - size.width / 2, y: margin)
        case .bottomRight:
            return CGPoint(x: pageRect.maxX - margin - size.width, y: margin)
        }
    }

    // MARK: - Reset

    func reset() {
        config = WatermarkConfig()
        customText = "CONFIDENTIAL"
        imageData = nil
        isPreviewVisible = false
    }
}
