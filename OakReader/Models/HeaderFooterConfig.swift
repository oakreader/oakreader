import Foundation
import AppKit

struct HeaderFooterConfig: Equatable {
    var headerLeft: String
    var headerCenter: String
    var headerRight: String
    var footerLeft: String
    var footerCenter: String
    var footerRight: String
    var fontName: String
    var fontSize: CGFloat
    var color: NSColor
    var margins: EdgeMargins
    var pageRange: PageRange
    var startPageNumber: Int
    var batesPrefix: String
    var batesSuffix: String
    var batesStartNumber: Int
    var batesDigits: Int
    var useBatesNumbering: Bool

    struct EdgeMargins: Equatable {
        var top: CGFloat
        var bottom: CGFloat
        var left: CGFloat
        var right: CGFloat

        static let `default` = EdgeMargins(top: 36, bottom: 36, left: 36, right: 36)
    }

    init() {
        self.headerLeft = ""
        self.headerCenter = ""
        self.headerRight = ""
        self.footerLeft = ""
        self.footerCenter = "<<page>>"
        self.footerRight = ""
        self.fontName = PDFDefaults.defaultFontName
        self.fontSize = 10
        self.color = .black
        self.margins = .default
        self.pageRange = .all
        self.startPageNumber = 1
        self.batesPrefix = ""
        self.batesSuffix = ""
        self.batesStartNumber = 1
        self.batesDigits = 6
        self.useBatesNumbering = false
    }

    func resolvedText(_ template: String, pageIndex: Int, totalPages: Int) -> String {
        var result = template
        let displayPage = pageIndex + startPageNumber
        result = result.replacingOccurrences(of: "<<page>>", with: "\(displayPage)")
        result = result.replacingOccurrences(of: "<<total>>", with: "\(totalPages)")
        result = result.replacingOccurrences(of: "<<date>>", with: DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none))
        if useBatesNumbering {
            let batesNumber = batesStartNumber + pageIndex
            let formatted = String(format: "%0\(batesDigits)d", batesNumber)
            result = result.replacingOccurrences(of: "<<bates>>", with: "\(batesPrefix)\(formatted)\(batesSuffix)")
        }
        return result
    }
}
