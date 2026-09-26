import Foundation

/// Position data for a PDF annotation, stored as JSON in `position_json`.
struct PDFAnnotationPosition: Codable {
    var pageIndex: Int
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var quadPoints: [[CGFloat]]?

    init(pageIndex: Int, bounds: CGRect, quadPoints: [[CGFloat]]? = nil) {
        self.pageIndex = pageIndex
        self.x = bounds.origin.x
        self.y = bounds.origin.y
        self.width = bounds.size.width
        self.height = bounds.size.height
        self.quadPoints = quadPoints
    }

    var bounds: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    func toJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func fromJSON(_ json: String) -> PDFAnnotationPosition? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PDFAnnotationPosition.self, from: data)
    }
}

/// Style data for a PDF annotation, stored as JSON in `style_json`.
struct AnnotationStyle: Codable {
    var lineWidth: CGFloat?
    var opacity: CGFloat?
    var fontName: String?
    var fontSize: CGFloat?
    var interiorColorHex: String?

    func toJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func fromJSON(_ json: String) -> AnnotationStyle? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AnnotationStyle.self, from: data)
    }
}
