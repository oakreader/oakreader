import Foundation
import PDFKit
import AppKit
import CoreImage

actor ComparisonService {

    func compare(
        _ doc1: PDFDocument,
        _ doc2: PDFDocument
    ) async -> [ComparisonResult] {
        let maxPages = max(doc1.pageCount, doc2.pageCount)
        var results: [ComparisonResult] = []

        for i in 0..<maxPages {
            var result = ComparisonResult(pageIndex: i)

            let page1 = doc1.page(at: i)
            let page2 = doc2.page(at: i)

            // Handle missing pages
            if page1 == nil, let p2 = page2 {
                result.differences.append(
                    ComparisonResult.Difference(
                        type: .textAdded,
                        bounds: p2.bounds(for: .mediaBox),
                        description: "Page \(i + 1) added in second document"
                    )
                )
                results.append(result)
                continue
            }
            if let p1 = page1, page2 == nil {
                result.differences.append(
                    ComparisonResult.Difference(
                        type: .textRemoved,
                        bounds: p1.bounds(for: .mediaBox),
                        description: "Page \(i + 1) removed in second document"
                    )
                )
                results.append(result)
                continue
            }

            guard let p1 = page1, let p2 = page2 else { continue }

            // Text comparison
            let text1 = p1.string ?? ""
            let text2 = p2.string ?? ""
            let pageRect = p1.bounds(for: .mediaBox)

            if text1 != text2 {
                let diffResults = String.diff(text1, text2)
                for diffItem in diffResults {
                    switch diffItem {
                    case .added(let line):
                        if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            result.differences.append(
                                ComparisonResult.Difference(
                                    type: .textAdded,
                                    bounds: pageRect,
                                    description: "Added: \(String(line.prefix(80)))"
                                )
                            )
                        }
                    case .removed(let line):
                        if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            result.differences.append(
                                ComparisonResult.Difference(
                                    type: .textRemoved,
                                    bounds: pageRect,
                                    description: "Removed: \(String(line.prefix(80)))"
                                )
                            )
                        }
                    case .unchanged:
                        break
                    }
                }
            }

            // Visual (pixel) comparison
            let dpi: CGFloat = 150
            if let img1 = p1.renderToCGImage(dpi: dpi),
               let img2 = p2.renderToCGImage(dpi: dpi) {

                let diffImage = computePixelDifference(img1, img2)
                if let diffImage {
                    result.diffImage = NSImage(cgImage: diffImage, size: NSSize(width: diffImage.width, height: diffImage.height))

                    if !hasDifference(img1, img2) {
                        // Images are identical; no visual difference
                    } else if result.differences.isEmpty {
                        // There are visual differences but no text differences
                        result.differences.append(
                            ComparisonResult.Difference(
                                type: .imageChanged,
                                bounds: pageRect,
                                description: "Visual differences detected on page \(i + 1)"
                            )
                        )
                    }
                }
            }

            results.append(result)
        }

        return results
    }

    // MARK: - Pixel Difference

    private func computePixelDifference(_ image1: CGImage, _ image2: CGImage) -> CGImage? {
        let ciImage1 = CIImage(cgImage: image1)
        let ciImage2 = CIImage(cgImage: image2)

        guard let filter = CIFilter(name: "CIDifferenceBlendMode") else { return nil }
        filter.setValue(ciImage1, forKey: kCIInputImageKey)
        filter.setValue(ciImage2, forKey: kCIInputBackgroundImageKey)

        guard let output = filter.outputImage else { return nil }

        let ciContext = CIContext()
        let extent = output.extent
        return ciContext.createCGImage(output, from: extent)
    }

    private func hasDifference(_ image1: CGImage, _ image2: CGImage) -> Bool {
        guard let diffImage = computePixelDifference(image1, image2) else { return true }

        let width = diffImage.width
        let height = diffImage.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let totalBytes = bytesPerRow * height

        var pixelData = [UInt8](repeating: 0, count: totalBytes)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }

        context.draw(diffImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Check if any pixel has a non-black value (indicating difference)
        let threshold: UInt8 = 10
        let totalPixels = width * height
        var differentPixels = 0

        for i in stride(from: 0, to: totalBytes, by: bytesPerPixel) {
            let r = pixelData[i]
            let g = pixelData[i + 1]
            let b = pixelData[i + 2]
            if r > threshold || g > threshold || b > threshold {
                differentPixels += 1
            }
        }

        // Consider different if more than 0.1% of pixels differ
        let percentDiff = Double(differentPixels) / Double(totalPixels)
        return percentDiff > 0.001
    }
}
