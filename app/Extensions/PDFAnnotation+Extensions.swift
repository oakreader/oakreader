import PDFKit
import AppKit

extension PDFAnnotation {
    static func rectangle(bounds: CGRect, color: NSColor = .red, fillColor: NSColor? = nil, lineWidth: CGFloat = 1.5) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        annotation.color = color
        annotation.interiorColor = fillColor
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        return annotation
    }
}
