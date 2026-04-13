import Foundation
import PDFKit
import AppKit

struct RedactionRegion: Identifiable, Equatable {
    let id: UUID
    var bounds: CGRect
    var pageIndex: Int
    var overlayColor: NSColor
    var overlayText: String?

    init(bounds: CGRect, pageIndex: Int, overlayColor: NSColor = .black, overlayText: String? = nil) {
        self.id = UUID()
        self.bounds = bounds
        self.pageIndex = pageIndex
        self.overlayColor = overlayColor
        self.overlayText = overlayText
    }

    func createMarkAnnotation() -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        annotation.color = NSColor.red.withAlphaComponent(0.3)
        annotation.interiorColor = NSColor.red.withAlphaComponent(0.1)
        let border = PDFBorder()
        border.lineWidth = 2.0
        border.style = .dashed
        annotation.border = border
        annotation.contents = "Marked for Redaction"
        return annotation
    }
}
