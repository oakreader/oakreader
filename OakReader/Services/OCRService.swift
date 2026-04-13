import Foundation
import PDFKit
import Vision
import AppKit

actor OCRService {

    // MARK: - Recognize Text

    func recognizeText(
        in page: PDFPage,
        language: String = "en"
    ) async throws -> [(String, CGRect)] {
        guard let cgImage = page.renderToCGImage(dpi: PDFDefaults.ocrDPI) else {
            throw OakReaderError.ocrFailed(page: 0, underlying: nil)
        }

        let pageRect = page.bounds(for: .mediaBox)
        let scale = PDFDefaults.ocrDPI / 72.0
        let imageWidth = pageRect.width * scale
        let imageHeight = pageRect.height * scale

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OakReaderError.ocrFailed(page: 0, underlying: error))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                var results: [(String, CGRect)] = []
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let text = candidate.string

                    // Vision returns normalized coordinates (0-1) with origin at bottom-left
                    let boundingBox = observation.boundingBox
                    let pdfRect = CGRect(
                        x: boundingBox.origin.x * pageRect.width + pageRect.origin.x,
                        y: boundingBox.origin.y * pageRect.height + pageRect.origin.y,
                        width: boundingBox.width * pageRect.width,
                        height: boundingBox.height * pageRect.height
                    )
                    results.append((text, pdfRect))
                }

                continuation.resume(returning: results)
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = [language]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: OakReaderError.ocrFailed(page: 0, underlying: error))
            }
        }
    }

    // MARK: - Apply OCR (make searchable)

    func applyOCR(
        to page: PDFPage,
        language: String = "en"
    ) async throws {
        let recognizedBlocks = try await recognizeText(in: page, language: language)

        for (text, rect) in recognizedBlocks {
            let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = NSFont(name: PDFDefaults.defaultFontName, size: max(rect.height * 0.8, 1))
            annotation.fontColor = NSColor.clear
            annotation.color = NSColor.clear
            let border = PDFBorder()
            border.lineWidth = 0
            annotation.border = border
            page.addAnnotation(annotation)
        }
    }

    // MARK: - OCR Full Document

    func ocrDocument(
        _ document: PDFDocument,
        pages: IndexSet,
        progressHandler: @Sendable (Double) -> Void
    ) async throws {
        let sortedPages = pages.sorted()
        let total = Double(sortedPages.count)
        guard total > 0 else { return }

        let maxConcurrency = min(ProcessInfo.processInfo.activeProcessorCount, 4)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var submitted = 0
            var completed = 0

            for pageIndex in sortedPages {
                if submitted - completed >= maxConcurrency {
                    try await group.next()
                    completed += 1
                    progressHandler(Double(completed) / total)
                }

                guard let page = document.page(at: pageIndex) else { continue }
                let language = Preferences.shared.ocrLanguage

                group.addTask { [self] in
                    try await self.applyOCR(to: page, language: language)
                }
                submitted += 1
            }

            while completed < submitted {
                try await group.next()
                completed += 1
                progressHandler(Double(completed) / total)
            }
        }
    }
}
