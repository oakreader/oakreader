import Foundation
import PDFKit
import AppKit

struct PrintService {

    func print(document: PDFDocument, printInfo: NSPrintInfo) {
        let pdfView = PDFView()
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.frame = NSRect(x: 0, y: 0, width: 612, height: 792)

        let printOperation = NSPrintOperation(view: pdfView, printInfo: printInfo)
        printOperation.showsPrintPanel = true
        printOperation.showsProgressPanel = true
        printOperation.run()
    }

    func printWithDefaults(document: PDFDocument) {
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true
        self.print(document: document, printInfo: printInfo)
    }

    func printPages(document: PDFDocument, pageRange: ClosedRange<Int>, printInfo: NSPrintInfo) {
        let tempDoc = PDFDocument()
        for i in pageRange {
            guard let page = document.page(at: i) else { continue }
            if let copiedPage = page.copy() as? PDFPage {
                tempDoc.insert(copiedPage, at: tempDoc.pageCount)
            }
        }

        guard tempDoc.pageCount > 0 else { return }
        self.print(document: tempDoc, printInfo: printInfo)
    }

    func createPrintInfo(
        orientation: NSPrintInfo.PaperOrientation = .portrait,
        scaling: CGFloat = 1.0,
        margins: NSEdgeInsets? = nil
    ) -> NSPrintInfo {
        let printInfo = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        printInfo.orientation = orientation
        printInfo.scalingFactor = scaling
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true

        if let margins {
            printInfo.topMargin = margins.top
            printInfo.bottomMargin = margins.bottom
            printInfo.leftMargin = margins.left
            printInfo.rightMargin = margins.right
        }

        return printInfo
    }
}
