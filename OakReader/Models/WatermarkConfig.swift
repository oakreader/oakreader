import Foundation
import AppKit

struct WatermarkConfig: Equatable {
    enum WatermarkType: Equatable {
        case text(String)
        case image(Data)
    }

    var type: WatermarkType
    var opacity: CGFloat
    var rotation: CGFloat  // degrees
    var position: WatermarkPosition
    var scale: CGFloat
    var fontSize: CGFloat
    var fontName: String
    var color: NSColor
    var isAboveContent: Bool
    var pageRange: PageRange

    init() {
        self.type = .text("CONFIDENTIAL")
        self.opacity = PDFDefaults.watermarkOpacity
        self.rotation = -45
        self.position = .center
        self.scale = 1.0
        self.fontSize = PDFDefaults.watermarkFontSize
        self.fontName = "Helvetica-Bold"
        self.color = .gray
        self.isAboveContent = true
        self.pageRange = .all
    }

    enum WatermarkPosition: String, CaseIterable {
        case center
        case topLeft, topCenter, topRight
        case bottomLeft, bottomCenter, bottomRight

        var label: String {
            switch self {
            case .center: return "Center"
            case .topLeft: return "Top Left"
            case .topCenter: return "Top Center"
            case .topRight: return "Top Right"
            case .bottomLeft: return "Bottom Left"
            case .bottomCenter: return "Bottom Center"
            case .bottomRight: return "Bottom Right"
            }
        }
    }
}

enum PageRange: Equatable {
    case all
    case range(ClosedRange<Int>)
    case custom([Int])

    var description: String {
        switch self {
        case .all: return "All Pages"
        case .range(let r): return "Pages \(r.lowerBound + 1)–\(r.upperBound + 1)"
        case .custom(let pages): return "Pages: \(pages.map { String($0 + 1) }.joined(separator: ", "))"
        }
    }

    func contains(_ pageIndex: Int) -> Bool {
        switch self {
        case .all: return true
        case .range(let r): return r.contains(pageIndex)
        case .custom(let pages): return pages.contains(pageIndex)
        }
    }
}
