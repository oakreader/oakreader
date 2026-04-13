import CoreGraphics
import AppKit
import PDFKit

extension CGContext {
    func drawPDFPageContent(_ page: PDFPage) {
        saveGState()
        let mediaBox = page.bounds(for: .mediaBox)
        translateBy(x: -mediaBox.origin.x, y: -mediaBox.origin.y)
        page.draw(with: .mediaBox, to: self)
        restoreGState()
    }

    func drawText(_ text: String, at point: CGPoint, font: NSFont, color: NSColor = .black) {
        saveGState()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attrString = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrString)

        textPosition = point
        CTLineDraw(line, self)
        restoreGState()
    }

    func drawCenteredText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor = .black) {
        saveGState()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attrString = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrString)
        let textBounds = CTLineGetBoundsWithOptions(line, [])

        let x = rect.midX - textBounds.width / 2
        let y = rect.midY - textBounds.height / 2

        textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, self)
        restoreGState()
    }

    func drawWhiteOut(over rect: CGRect) {
        saveGState()
        setFillColor(NSColor.white.cgColor)
        fill(rect)
        restoreGState()
    }

    func drawWatermarkText(_ text: String, in pageRect: CGRect, font: NSFont, color: NSColor, opacity: CGFloat, rotation: CGFloat) {
        saveGState()
        setAlpha(opacity)

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attrString = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrString)
        let textBounds = CTLineGetBoundsWithOptions(line, [])

        translateBy(x: pageRect.midX, y: pageRect.midY)
        rotate(by: rotation * .pi / 180)
        translateBy(x: -textBounds.width / 2, y: -textBounds.height / 2)

        textPosition = .zero
        CTLineDraw(line, self)

        restoreGState()
    }

    func drawWatermarkImage(_ image: CGImage, in pageRect: CGRect, opacity: CGFloat, scale: CGFloat) {
        saveGState()
        setAlpha(opacity)

        let imgWidth = CGFloat(image.width) * scale
        let imgHeight = CGFloat(image.height) * scale
        let x = pageRect.midX - imgWidth / 2
        let y = pageRect.midY - imgHeight / 2

        draw(image, in: CGRect(x: x, y: y, width: imgWidth, height: imgHeight))

        restoreGState()
    }

    func drawRedaction(over rect: CGRect, color: NSColor = .black, overlayText: String? = nil) {
        saveGState()
        setFillColor(color.cgColor)
        fill(rect)

        if let text = overlayText, !text.isEmpty {
            let font = NSFont.systemFont(ofSize: 8)
            let textColor: NSColor = color == .black ? .white : .black
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor
            ]
            let attrString = NSAttributedString(string: text, attributes: attrs)
            let line = CTLineCreateWithAttributedString(attrString)
            textPosition = CGPoint(x: rect.origin.x + 2, y: rect.origin.y + 2)
            CTLineDraw(line, self)
        }
        restoreGState()
    }
}
