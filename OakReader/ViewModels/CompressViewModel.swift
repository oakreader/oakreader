import Foundation
import PDFKit
import AppKit

@Observable
class CompressViewModel {
    weak var parent: DocumentViewModel?

    var targetQuality: CompressionQuality = Preferences.shared.compressionQuality
    var removeMetadata: Bool = false
    var downsampleImages: Bool = true
    var isProcessing: Bool = false
    var progress: Double = 0
    var originalSize: Int64?
    var compressedSize: Int64?
    var flattenAnnotations: Bool = false
    var removeBookmarks: Bool = false

    init(parent: DocumentViewModel) {
        self.parent = parent
        calculateOriginalSize()
    }

    private var pdfDocument: PDFDocument? { parent?.pdfDocument }

    // MARK: - Size Calculation

    func calculateOriginalSize() {
        guard let doc = pdfDocument else {
            originalSize = nil
            return
        }
        originalSize = doc.fileSizeEstimate()
    }

    var originalSizeLabel: String {
        guard let size = originalSize else { return "Unknown" }
        return FileCoordination.fileSizeString(bytes: size)
    }

    var compressedSizeLabel: String {
        guard let size = compressedSize else { return "Not yet compressed" }
        return FileCoordination.fileSizeString(bytes: size)
    }

    var savingsLabel: String {
        guard let original = originalSize, let compressed = compressedSize, original > 0 else {
            return ""
        }
        let savings = original - compressed
        let percentage = Double(savings) / Double(original) * 100
        if savings > 0 {
            return "Saved \(FileCoordination.fileSizeString(bytes: savings)) (\(Int(percentage))%)"
        } else {
            return "No size reduction achieved"
        }
    }

    var estimatedSizeLabel: String {
        guard let original = originalSize else { return "" }
        // Rough estimate based on quality
        let factor: Double
        switch targetQuality {
        case .low: factor = 0.25
        case .medium: factor = 0.5
        case .high: factor = 0.75
        case .maximum: factor = 0.9
        }
        let estimated = Int64(Double(original) * factor)
        return "~\(FileCoordination.fileSizeString(bytes: estimated))"
    }

    // MARK: - Compress

    func compress() async {
        guard let doc = pdfDocument else { return }

        await MainActor.run {
            isProcessing = true
            progress = 0
            compressedSize = nil
        }

        let tempURL = FileCoordination.temporaryURL()
        let quality = targetQuality
        let shouldFlatten = flattenAnnotations
        let shouldRemoveBookmarks = removeBookmarks
        let shouldRemoveMetadata = removeMetadata
        let shouldDownsampleImages = downsampleImages

        do {
            // Step 1: Optionally flatten annotations
            if shouldFlatten {
                doc.flattenAnnotations()
            }

            // Step 2: Optionally remove bookmarks
            if shouldRemoveBookmarks {
                doc.outlineRoot = nil
            }

            // Step 3: Rewrite the document with compression
            var options: [String: Any] = [:]

            if shouldRemoveMetadata {
                // Clear metadata
                options[kCGPDFContextAuthor as String] = ""
                options[kCGPDFContextTitle as String] = ""
                options[kCGPDFContextSubject as String] = ""
                options[kCGPDFContextKeywords as String] = ""
                options[kCGPDFContextCreator as String] = ""
            }

            // Rewrite with image downsampling
            if shouldDownsampleImages {
                try await rewriteWithDownsampling(doc: doc, to: tempURL, quality: quality, options: options)
            } else {
                try PDFRewriter.rewriteDocument(doc, to: tempURL, options: options)
            }

            // Measure the result
            let resultData: Data
            if let data = try? Data(contentsOf: tempURL) {
                resultData = data
            } else {
                throw OakReaderError.compressionFailed(underlying: nil)
            }

            let newSize = Int64(resultData.count)

            // Only use the compressed version if it's actually smaller
            let currentData = doc.dataRepresentation()
            let currentSize = Int64(currentData?.count ?? 0)

            if newSize < currentSize {
                // Replace the document's pages with the compressed version
                if let compressedDoc = PDFDocument(data: resultData) {
                    await MainActor.run {
                        let pageCount = doc.pageCount
                        // Remove all current pages and insert compressed pages
                        for i in (0..<pageCount).reversed() {
                            doc.removePage(at: i)
                        }
                        for i in 0..<compressedDoc.pageCount {
                            if let page = compressedDoc.page(at: i),
                               let copied = page.copy() as? PDFPage {
                                doc.insert(copied, at: i)
                            }
                        }
                    }
                }
                await MainActor.run {
                    compressedSize = newSize
                }
            } else {
                await MainActor.run {
                    compressedSize = currentSize
                }
            }

            try? FileManager.default.removeItem(at: tempURL)

            await MainActor.run {
                isProcessing = false
                progress = 1.0
                parent?.markDocumentEdited()
            }

        } catch {
            await MainActor.run {
                isProcessing = false
                parent?.state.presentError("Compression failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Image Downsampling Rewrite

    private func rewriteWithDownsampling(doc: PDFDocument, to outputURL: URL, quality: CompressionQuality, options: [String: Any]) async throws {
        let maxDPI = CGFloat(quality.maxDPI)
        let jpegQuality = quality.jpegQuality
        let totalPages = doc.pageCount

        // For each page, render at reduced DPI and create a new PDF
        let data = NSMutableData()
        guard let firstPage = doc.page(at: 0) else {
            throw OakReaderError.invalidPDF
        }
        var mediaBox = firstPage.bounds(for: .mediaBox)

        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, options as CFDictionary) else {
            throw OakReaderError.compressionFailed(underlying: nil)
        }

        for pageIndex in 0..<totalPages {
            guard let page = doc.page(at: pageIndex) else { continue }
            let pageBox = page.bounds(for: .mediaBox)

            let pageInfo: [String: Any] = [
                kCGPDFContextMediaBox as String: NSValue(rect: pageBox)
            ]
            context.beginPDFPage(pageInfo as CFDictionary)

            // Check if the page has text content
            if page.hasText {
                // For pages with text, draw the original content to preserve text quality
                context.saveGState()
                if let cgPage = page.pageRef {
                    context.translateBy(x: -pageBox.origin.x, y: -pageBox.origin.y)
                    context.drawPDFPage(cgPage)
                }
                context.restoreGState()
            } else {
                // For image-only pages, render at reduced quality
                if let cgImage = page.renderToCGImage(dpi: maxDPI) {
                    // Re-compress as JPEG
                    let nsImage = NSImage.from(cgImage: cgImage)
                    if let jpegData = nsImage.jpegData(quality: jpegQuality),
                       let jpegImage = NSImage(data: jpegData),
                       let finalCGImage = jpegImage.cgImage {
                        context.saveGState()
                        context.draw(finalCGImage, in: CGRect(origin: .zero, size: pageBox.size))
                        context.restoreGState()
                    } else {
                        // Fallback: draw the original
                        context.saveGState()
                        context.draw(cgImage, in: CGRect(origin: .zero, size: pageBox.size))
                        context.restoreGState()
                    }
                } else {
                    // Fallback: draw original page
                    context.saveGState()
                    if let cgPage = page.pageRef {
                        context.translateBy(x: -pageBox.origin.x, y: -pageBox.origin.y)
                        context.drawPDFPage(cgPage)
                    }
                    context.restoreGState()
                }
            }

            context.endPDFPage()

            await MainActor.run { [weak self] in
                self?.progress = Double(pageIndex + 1) / Double(totalPages)
            }
        }

        context.closePDF()

        // Write the data to the output URL
        try (data as Data).write(to: outputURL)
    }

    // MARK: - Reset

    func reset() {
        targetQuality = .medium
        removeMetadata = false
        downsampleImages = true
        flattenAnnotations = false
        removeBookmarks = false
        compressedSize = nil
        progress = 0
        calculateOriginalSize()
    }
}
