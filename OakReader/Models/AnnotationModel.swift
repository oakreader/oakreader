import Foundation
import PDFKit
import AppKit

struct AnnotationModel: Identifiable, Equatable {
    let id: UUID
    var type: PDFAnnotationSubtype
    var bounds: CGRect
    var color: NSColor
    var contents: String?
    /// The text content under a markup annotation (highlight, underline, etc.)
    var markedUpText: String?
    var fontName: String?
    var fontSize: CGFloat?
    var lineWidth: CGFloat
    var opacity: CGFloat
    var pageIndex: Int
    var interiorColor: NSColor?

    init(from annotation: PDFAnnotation, pageIndex: Int) {
        self.id = UUID()
        self.type = PDFAnnotationSubtype(rawValue: annotation.type ?? "")
        self.bounds = annotation.bounds
        self.color = annotation.color
        self.contents = annotation.contents
        self.fontName = annotation.font?.fontName
        self.fontSize = annotation.font?.pointSize
        self.lineWidth = annotation.border?.lineWidth ?? 1.0
        self.opacity = CGFloat(annotation.value(forAnnotationKey: .color) != nil ? 1.0 : 1.0)
        self.pageIndex = pageIndex
        self.interiorColor = annotation.interiorColor

        // Extract marked-up text from the page for markup annotations
        if let page = annotation.page {
            let selection = page.selection(for: annotation.bounds)
            self.markedUpText = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Build a sidebar model from a DB-backed overlay markup (no PDFAnnotation).
    init(overlayMarkup markup: PDFTextMarkup, pageIndex: Int) {
        self.id = UUID()
        self.type = markup.kind.subtype
        self.bounds = markup.quads.first ?? .zero
        self.color = markup.color
        self.contents = markup.comment
        self.markedUpText = markup.text
        self.fontName = nil
        self.fontSize = nil
        self.lineWidth = 1.0
        self.opacity = markup.color.alphaComponent
        self.pageIndex = pageIndex
        self.interiorColor = nil
    }

    init(type: PDFAnnotationSubtype, bounds: CGRect, pageIndex: Int) {
        self.id = UUID()
        self.type = type
        self.bounds = bounds
        self.color = PDFDefaults.annotationDefaultColor
        self.contents = nil
        self.fontName = PDFDefaults.defaultFontName
        self.fontSize = PDFDefaults.defaultFontSize
        self.lineWidth = PDFDefaults.annotationDefaultLineWidth
        self.opacity = 1.0
        self.pageIndex = pageIndex
        self.interiorColor = nil
    }

    func apply(to annotation: PDFAnnotation) {
        annotation.bounds = bounds
        annotation.color = color
        annotation.contents = contents
        if let fontName, let fontSize {
            annotation.font = NSFont(name: fontName, size: fontSize)
        }
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        if let interiorColor {
            annotation.interiorColor = interiorColor
        }
    }

    static func snapshot(of annotation: PDFAnnotation, pageIndex: Int) -> AnnotationModel {
        AnnotationModel(from: annotation, pageIndex: pageIndex)
    }
}
