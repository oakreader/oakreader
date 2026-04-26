import PDFKit
import AppKit

extension PDFAnnotation {
    static func highlight(bounds: CGRect, color: NSColor = PDFDefaults.highlightColor) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = color
        return annotation
    }

    static func underline(bounds: CGRect, color: NSColor = .red) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .underline, withProperties: nil)
        annotation.color = color
        return annotation
    }

    static func strikethrough(bounds: CGRect, color: NSColor = .red) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .strikeOut, withProperties: nil)
        annotation.color = color
        return annotation
    }

    static func freeText(bounds: CGRect, text: String, font: NSFont? = nil, color: NSColor = .black) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = font ?? NSFont(name: PDFDefaults.defaultFontName, size: PDFDefaults.defaultFontSize)
        annotation.fontColor = color
        annotation.color = .clear
        return annotation
    }

    static func line(from start: CGPoint, to end: CGPoint, color: NSColor = .red, lineWidth: CGFloat = 1.5) -> PDFAnnotation {
        let bounds = CGRect(
            x: min(start.x, end.x) - lineWidth,
            y: min(start.y, end.y) - lineWidth,
            width: abs(end.x - start.x) + lineWidth * 2,
            height: abs(end.y - start.y) + lineWidth * 2
        )
        let annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
        annotation.startPoint = start
        annotation.endPoint = end
        annotation.color = color
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        return annotation
    }

    static func rectangle(bounds: CGRect, color: NSColor = .red, fillColor: NSColor? = nil, lineWidth: CGFloat = 1.5) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
        annotation.color = color
        annotation.interiorColor = fillColor
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        return annotation
    }

    static func oval(bounds: CGRect, color: NSColor = .red, fillColor: NSColor? = nil, lineWidth: CGFloat = 1.5) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .circle, withProperties: nil)
        annotation.color = color
        annotation.interiorColor = fillColor
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        return annotation
    }

    private static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    static func link(bounds: CGRect, url: URL) -> PDFAnnotation? {
        // Security: only allow safe URL schemes
        guard let scheme = url.scheme?.lowercased(),
              allowedLinkSchemes.contains(scheme) else {
            return nil
        }
        let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        annotation.url = url
        return annotation
    }

    static func link(bounds: CGRect, destination: PDFDestination) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        annotation.destination = destination
        return annotation
    }

    var displayName: String {
        switch type {
        case "Highlight": return "Highlight"
        case "Underline": return "Underline"
        case "StrikeOut": return "Strikethrough"
        case "Text": return "Sticky Note"
        case "FreeText": return "Text"
        case "Ink": return "Drawing"
        case "Line": return "Line"
        case "Square": return "Rectangle"
        case "Circle": return "Oval"
        case "Stamp": return "Stamp"
        case "Link": return "Link"
        case "Widget": return "Form Field"
        default: return type ?? "Annotation"
        }
    }
}
