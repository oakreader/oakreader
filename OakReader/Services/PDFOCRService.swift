import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// On-device OCR using Apple's Vision framework. Renders to a bitmap and runs
/// `VNRecognizeTextRequest`. Heavy (seconds per page) — run off the main thread.
enum PDFOCRService {

    /// OCR a standalone image (e.g. a Translation region snapshot) into plain
    /// text, joining recognized lines top-to-bottom. Returns "" on failure or
    /// when no text is found. Heavy — call off the main thread.
    static func recognizeText(
        inPNG pngData: Data,
        languages: [String] = ["en-US", "zh-Hans"]
    ) -> String {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Log.error(Log.ocr, "OCR: cannot decode region snapshot image")
            return ""
        }
        return recognize(image, languages: languages)
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
            Log.error(Log.ocr, "OCR: Vision request failed: \(error)")
            return ""
        }

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
