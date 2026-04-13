import Foundation
import PDFKit
import AppKit

@Observable
class CompareViewModel {
    weak var parent: DocumentViewModel?

    var document1: PDFDocument?
    var document2: PDFDocument?
    var results: [ComparisonResult] = []
    var isComparing: Bool = false
    var progress: Double = 0
    var selectedDifferenceIndex: Int?
    var showOnlyDifferences: Bool = false

    init(parent: DocumentViewModel) {
        self.parent = parent
        // Use the current document as document1 by default
        self.document1 = parent.pdfDocument
    }

    private var pdfDocument: PDFDocument? { parent?.pdfDocument }

    // MARK: - Load Documents

    func loadDocument1(from url: URL) {
        document1 = PDFDocument(url: url)
    }

    func loadDocument2(from url: URL) {
        document2 = PDFDocument(url: url)
    }

    func useCurrentDocumentAsDocument1() {
        document1 = pdfDocument
    }

    // MARK: - Compare

    func compare() async {
        guard let doc1 = document1, let doc2 = document2 else {
            await MainActor.run {
                parent?.state.presentError("Both documents must be loaded for comparison.")
            }
            return
        }

        await MainActor.run {
            isComparing = true
            progress = 0
            results = []
            selectedDifferenceIndex = nil
        }

        let maxPages = max(doc1.pageCount, doc2.pageCount)

        var comparisonResults: [ComparisonResult] = []

        for pageIndex in 0..<maxPages {
            let page1 = doc1.page(at: pageIndex)
            let page2 = doc2.page(at: pageIndex)

            var result = ComparisonResult(pageIndex: pageIndex)

            if page1 == nil, let p2 = page2 {
                // Page only in document 2
                result.differences.append(
                    ComparisonResult.Difference(
                        type: .textAdded,
                        bounds: p2.bounds(for: .mediaBox),
                        description: "Page \(pageIndex + 1) only exists in document 2"
                    )
                )
            } else if let p1 = page1, page2 == nil {
                // Page only in document 1
                result.differences.append(
                    ComparisonResult.Difference(
                        type: .textRemoved,
                        bounds: p1.bounds(for: .mediaBox),
                        description: "Page \(pageIndex + 1) only exists in document 1"
                    )
                )
            } else if let p1 = page1, let p2 = page2 {
                // Compare text content
                let text1 = p1.string ?? ""
                let text2 = p2.string ?? ""

                if text1 != text2 {
                    let diffResults = String.diff(text1, text2)
                    let pageBounds = p1.bounds(for: .mediaBox)

                    for diff in diffResults {
                        switch diff {
                        case .added(let line):
                            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                result.differences.append(
                                    ComparisonResult.Difference(
                                        type: .textAdded,
                                        bounds: pageBounds,
                                        description: "Added: \(line.prefix(80))"
                                    )
                                )
                            }
                        case .removed(let line):
                            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                result.differences.append(
                                    ComparisonResult.Difference(
                                        type: .textRemoved,
                                        bounds: pageBounds,
                                        description: "Removed: \(line.prefix(80))"
                                    )
                                )
                            }
                        case .unchanged:
                            break
                        }
                    }
                }

                // Compare annotations
                let anns1 = p1.annotations.filter { $0.type != "Widget" }
                let anns2 = p2.annotations.filter { $0.type != "Widget" }

                if anns1.count != anns2.count {
                    result.differences.append(
                        ComparisonResult.Difference(
                            type: .annotationChanged,
                            bounds: p1.bounds(for: .mediaBox),
                            description: "Annotation count changed: \(anns1.count) -> \(anns2.count)"
                        )
                    )
                }

                // Visual comparison: render pages and compare pixel data
                if let img1 = p1.renderToCGImage(dpi: 72),
                   let img2 = p2.renderToCGImage(dpi: 72) {
                    let diffImage = generateDiffImage(img1, img2, pageSize: p1.bounds(for: .mediaBox).size)
                    result.diffImage = diffImage
                }
            }

            comparisonResults.append(result)

            await MainActor.run {
                progress = Double(pageIndex + 1) / Double(maxPages)
            }
        }

        await MainActor.run {
            results = comparisonResults
            isComparing = false
            progress = 1.0
        }
    }

    // MARK: - Navigation

    func selectDifference(at index: Int) {
        guard index >= 0, index < results.count else { return }
        selectedDifferenceIndex = index
        let result = results[index]
        parent?.viewer.goToPage(result.pageIndex)
    }

    func nextDifference() {
        guard !results.isEmpty else { return }
        let diffsOnly = results.enumerated().filter { $0.element.hasDifferences }
        guard !diffsOnly.isEmpty else { return }

        let currentIdx = selectedDifferenceIndex ?? -1
        if let next = diffsOnly.first(where: { $0.offset > currentIdx }) {
            selectDifference(at: next.offset)
        } else {
            selectDifference(at: diffsOnly[0].offset)
        }
    }

    func previousDifference() {
        guard !results.isEmpty else { return }
        let diffsOnly = results.enumerated().filter { $0.element.hasDifferences }
        guard !diffsOnly.isEmpty else { return }

        let currentIdx = selectedDifferenceIndex ?? results.count
        if let prev = diffsOnly.last(where: { $0.offset < currentIdx }) {
            selectDifference(at: prev.offset)
        } else {
            if let last = diffsOnly.last {
                selectDifference(at: last.offset)
            }
        }
    }

    // MARK: - Summary

    var totalDifferences: Int {
        results.reduce(0) { $0 + $1.differences.count }
    }

    var pagesWithDifferences: Int {
        results.filter { $0.hasDifferences }.count
    }

    var comparisonSummary: String {
        guard !results.isEmpty else { return "No comparison performed" }
        let total = totalDifferences
        let pages = pagesWithDifferences
        if total == 0 {
            return "Documents are identical"
        }
        return "\(total) difference\(total == 1 ? "" : "s") found across \(pages) page\(pages == 1 ? "" : "s")"
    }

    // MARK: - Reset

    func reset() {
        document2 = nil
        results = []
        selectedDifferenceIndex = nil
        progress = 0
        isComparing = false
    }

    // MARK: - Visual Diff

    private func generateDiffImage(_ image1: CGImage, _ image2: CGImage, pageSize: CGSize) -> NSImage {
        let width = min(image1.width, image2.width)
        let height = min(image1.height, image2.height)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(size: pageSize)
        }

        // Draw image1 as the base
        context.draw(image1, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Get pixel data for both images
        guard let data1 = image1.dataProvider?.data,
              let data2 = image2.dataProvider?.data else {
            return NSImage(size: pageSize)
        }

        guard let ptr1 = CFDataGetBytePtr(data1),
              let ptr2 = CFDataGetBytePtr(data2) else {
            return NSImage(size: pageSize)
        }
        let byteCount1 = CFDataGetLength(data1)
        let byteCount2 = CFDataGetLength(data2)

        let bytesPerPixel = 4
        let pixelCount = min(byteCount1, byteCount2) / bytesPerPixel

        // Highlight differing pixels in red
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image1, in: CGRect(x: 0, y: 0, width: width, height: height))

        context.setFillColor(NSColor.red.withAlphaComponent(0.3).cgColor)

        for pixel in 0..<min(pixelCount, width * height) {
            let offset = pixel * bytesPerPixel
            guard offset + 3 < byteCount1, offset + 3 < byteCount2 else { break }

            let r1 = ptr1[offset], g1 = ptr1[offset+1], b1 = ptr1[offset+2]
            let r2 = ptr2[offset], g2 = ptr2[offset+1], b2 = ptr2[offset+2]

            let diff = abs(Int(r1) - Int(r2)) + abs(Int(g1) - Int(g2)) + abs(Int(b1) - Int(b2))
            if diff > 30 { // Threshold for pixel difference
                let x = pixel % width
                let y = pixel / width
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }

        guard let resultImage = context.makeImage() else {
            return NSImage(size: pageSize)
        }

        return NSImage.from(cgImage: resultImage)
    }
}
