import Foundation
import PDFKit

struct SplitService {

    func split(_ document: PDFDocument, at pageIndex: Int) -> (PDFDocument, PDFDocument) {
        let first = PDFDocument()
        let second = PDFDocument()

        let splitPoint = min(max(pageIndex, 0), document.pageCount)

        for i in 0..<splitPoint {
            guard let page = document.page(at: i) else { continue }
            if let copiedPage = page.copy() as? PDFPage {
                first.insert(copiedPage, at: first.pageCount)
            }
        }

        for i in splitPoint..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            if let copiedPage = page.copy() as? PDFPage {
                second.insert(copiedPage, at: second.pageCount)
            }
        }

        return (first, second)
    }

    func splitIntoSinglePages(_ document: PDFDocument) -> [PDFDocument] {
        var results: [PDFDocument] = []

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let singleDoc = PDFDocument()
            if let copiedPage = page.copy() as? PDFPage {
                singleDoc.insert(copiedPage, at: 0)
            }
            results.append(singleDoc)
        }

        return results
    }

    func splitByRanges(_ document: PDFDocument, ranges: [ClosedRange<Int>]) -> [PDFDocument] {
        var results: [PDFDocument] = []

        for range in ranges {
            let doc = PDFDocument()
            let clampedLower = max(range.lowerBound, 0)
            let clampedUpper = min(range.upperBound, document.pageCount - 1)

            guard clampedLower <= clampedUpper else {
                results.append(doc)
                continue
            }

            for i in clampedLower...clampedUpper {
                guard let page = document.page(at: i) else { continue }
                if let copiedPage = page.copy() as? PDFPage {
                    doc.insert(copiedPage, at: doc.pageCount)
                }
            }
            results.append(doc)
        }

        return results
    }

    func splitEveryN(_ document: PDFDocument, pagesPerChunk: Int) -> [PDFDocument] {
        guard pagesPerChunk > 0 else { return [] }
        var results: [PDFDocument] = []
        var currentDoc = PDFDocument()

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            if let copiedPage = page.copy() as? PDFPage {
                currentDoc.insert(copiedPage, at: currentDoc.pageCount)
            }

            if currentDoc.pageCount >= pagesPerChunk {
                results.append(currentDoc)
                currentDoc = PDFDocument()
            }
        }

        if currentDoc.pageCount > 0 {
            results.append(currentDoc)
        }

        return results
    }
}
