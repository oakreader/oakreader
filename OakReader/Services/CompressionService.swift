import Foundation
import PDFKit
import CoreGraphics
import AppKit

struct CompressionStats {
    let originalSize: Int64
    let compressedSize: Int64

    var ratio: Double {
        guard originalSize > 0 else { return 0 }
        return 1.0 - (Double(compressedSize) / Double(originalSize))
    }

    var savings: Int64 {
        originalSize - compressedSize
    }

    var formattedOriginalSize: String {
        FileCoordination.fileSizeString(bytes: originalSize)
    }

    var formattedCompressedSize: String {
        FileCoordination.fileSizeString(bytes: compressedSize)
    }

    var formattedRatio: String {
        String(format: "%.1f%%", ratio * 100)
    }
}

actor CompressionService {

    func compress(
        _ document: PDFDocument,
        quality: CompressionQuality,
        removeMetadata: Bool = false
    ) async throws -> (Data, CompressionStats) {
        guard let originalData = document.dataRepresentation() else {
            throw OakReaderError.compressionFailed(underlying: nil)
        }
        let originalSize = Int64(originalData.count)

        let tempURL = FileCoordination.temporaryURL(for: "compressed_\(UUID().uuidString)")

        guard document.pageCount > 0 else {
            throw OakReaderError.invalidPDF
        }

        guard let firstPage = document.page(at: 0) else {
            throw OakReaderError.invalidPDF
        }
        var mediaBox = firstPage.bounds(for: .mediaBox)

        var contextOptions: [String: Any] = [:]
        if removeMetadata {
            contextOptions[kCGPDFContextAuthor as String] = ""
            contextOptions[kCGPDFContextTitle as String] = ""
            contextOptions[kCGPDFContextSubject as String] = ""
            contextOptions[kCGPDFContextKeywords as String] = ""
            contextOptions[kCGPDFContextCreator as String] = ""
        }

        guard let context = CGContext(tempURL as CFURL, mediaBox: &mediaBox, contextOptions as CFDictionary) else {
            throw OakReaderError.compressionFailed(underlying: nil)
        }

        let renderDPI = CGFloat(quality.maxDPI)
        let jpegQuality = quality.jpegQuality

        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let pageBox = page.bounds(for: .mediaBox)

            let pageInfo: [String: Any] = [
                kCGPDFContextMediaBox as String: NSValue(rect: pageBox)
            ]
            context.beginPDFPage(pageInfo as CFDictionary)

            // Render the page to an image at the target DPI, then compress as JPEG
            let scale = renderDPI / 72.0
            let pixelWidth = Int(pageBox.width * scale)
            let pixelHeight = Int(pageBox.height * scale)

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard let bitmapContext = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                context.endPDFPage()
                continue
            }

            bitmapContext.setFillColor(NSColor.white.cgColor)
            bitmapContext.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            bitmapContext.scaleBy(x: scale, y: scale)
            bitmapContext.translateBy(x: -pageBox.origin.x, y: -pageBox.origin.y)

            page.draw(with: .mediaBox, to: bitmapContext)

            if let renderedImage = bitmapContext.makeImage() {
                // Compress via JPEG re-encoding
                let nsImage = NSImage(cgImage: renderedImage, size: NSSize(width: pixelWidth, height: pixelHeight))
                if let tiffData = nsImage.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiffData),
                   let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality]),
                   let jpegProvider = CGDataProvider(data: jpegData as CFData),
                   let jpegImage = CGImage(
                       jpegDataProviderSource: jpegProvider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent
                   ) {
                    context.draw(jpegImage, in: CGRect(origin: pageBox.origin, size: pageBox.size))
                } else {
                    // Fall back to drawing the rendered image directly
                    context.draw(renderedImage, in: CGRect(origin: pageBox.origin, size: pageBox.size))
                }
            } else {
                // Fall back to drawing the original page
                if let cgPage = page.pageRef {
                    context.translateBy(x: -pageBox.origin.x, y: -pageBox.origin.y)
                    context.drawPDFPage(cgPage)
                }
            }

            context.endPDFPage()
        }

        context.closePDF()

        guard let compressedData = try? Data(contentsOf: tempURL) else {
            throw OakReaderError.compressionFailed(underlying: nil)
        }

        try? FileManager.default.removeItem(at: tempURL)

        let compressedSize = Int64(compressedData.count)
        let stats = CompressionStats(originalSize: originalSize, compressedSize: compressedSize)

        return (compressedData, stats)
    }
}
