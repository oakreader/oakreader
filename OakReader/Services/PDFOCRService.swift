import CoreGraphics
import Foundation
import PDFKit
import Vision

/// On-device OCR for image-only / scanned PDFs, using Apple's Vision framework.
/// Each page is rendered to a bitmap and run through `VNRecognizeTextRequest`, then
/// chunked page-anchored so OCR'd text lands in the same citable shape as extracted
/// text. Heavy (seconds per document) — run off the main thread, one doc at a time.
enum PDFOCRService {

    /// OCR every page of a PDF into page-anchored chunks. Pages that yield no text are
    /// skipped; an all-blank document returns `[]`. Respects task cancellation.
    static func recognizeChunks(
        pdfURL: URL,
        languages: [String] = ["zh-Hans", "en-US"]
    ) -> [ContentChunker.Chunk] {
        guard let doc = PDFDocument(url: pdfURL) else {
            Log.error(Log.fts, "OCR: cannot open PDF \(pdfURL.lastPathComponent)")
            return []
        }

        var chunks: [ContentChunker.Chunk] = []
        for i in 0..<doc.pageCount {
            if Task.isCancelled { break }
            guard let page = doc.page(at: i), let image = renderPage(page) else { continue }
            let text = recognize(image, languages: languages)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            chunks += ContentChunker.chunkPlainText(text, type: "page", pageStart: i, pageEnd: i)
        }
        return chunks
    }

    /// Render a PDF page to a white-backed RGB bitmap at `scale`× for OCR. 2× gives
    /// Vision enough resolution on small body text without ballooning memory.
    private static func renderPage(_ page: PDFPage, scale: CGFloat = 2.0) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return nil }

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    /// Run Vision text recognition over a single page image, joining lines top-to-bottom.
    private static func recognize(_ image: CGImage, languages: [String]) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Log.error(Log.fts, "OCR: Vision request failed: \(error)")
            return ""
        }

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
