import Foundation
import PDFKit
import AppKit
import Vision

@Observable
class OCRViewModel {
    weak var parent: DocumentViewModel?

    var isProcessing: Bool = false
    var progress: Double = 0
    var recognizedPages: Set<Int> = []
    var language: String = Preferences.shared.ocrLanguage
    var recognizedText: [Int: String] = [:]

    // MARK: - Supported Languages

    static let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"),
        ("fr", "French"),
        ("de", "German"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("zh-Hans", "Chinese (Simplified)"),
        ("zh-Hant", "Chinese (Traditional)"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
    ]

    init(parent: DocumentViewModel) {
        self.parent = parent
    }

    private var pdfDocument: PDFDocument? { parent?.pdfDocument }

    // MARK: - Run OCR on a Single Page

    func runOCR(on pageIndex: Int) async {
        guard let doc = pdfDocument,
              let page = doc.page(at: pageIndex) else { return }

        await MainActor.run {
            isProcessing = true
            progress = 0
        }

        do {
            let text = try await recognizeText(on: page, pageIndex: pageIndex)

            await MainActor.run {
                recognizedText[pageIndex] = text
                recognizedPages.insert(pageIndex)

                // Add an invisible text layer to the page if it doesn't have text
                if !page.hasText && !text.isEmpty {
                    addTextOverlay(text: text, to: page)
                    parent?.markDocumentEdited()
                }

                isProcessing = false
                progress = 1.0
            }
        } catch {
            await MainActor.run {
                isProcessing = false
                parent?.state.presentError("OCR failed on page \(pageIndex + 1): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Run OCR on All Pages

    func runOCROnAllPages() async {
        guard let doc = pdfDocument else { return }

        await MainActor.run {
            isProcessing = true
            progress = 0
            recognizedPages.removeAll()
            recognizedText.removeAll()
        }

        let totalPages = doc.pageCount
        var failedPages: [Int] = []

        for pageIndex in 0..<totalPages {
            guard let page = doc.page(at: pageIndex) else { continue }

            // Skip pages that already have text content
            if page.hasText {
                await MainActor.run {
                    recognizedPages.insert(pageIndex)
                    recognizedText[pageIndex] = page.string ?? ""
                    progress = Double(pageIndex + 1) / Double(totalPages)
                }
                continue
            }

            do {
                let text = try await recognizeText(on: page, pageIndex: pageIndex)

                await MainActor.run {
                    recognizedText[pageIndex] = text
                    recognizedPages.insert(pageIndex)

                    if !text.isEmpty {
                        addTextOverlay(text: text, to: page)
                    }

                    progress = Double(pageIndex + 1) / Double(totalPages)
                }
            } catch {
                failedPages.append(pageIndex)
                await MainActor.run {
                    progress = Double(pageIndex + 1) / Double(totalPages)
                }
            }
        }

        await MainActor.run {
            isProcessing = false
            progress = 1.0

            if !recognizedPages.isEmpty {
                parent?.markDocumentEdited()
            }

            if !failedPages.isEmpty {
                let pageNumbers = failedPages.map { String($0 + 1) }.joined(separator: ", ")
                parent?.state.presentError("OCR failed on page(s): \(pageNumbers)")
            }
        }
    }

    // MARK: - Run OCR on Selected Pages

    func runOCR(onPages pageIndices: [Int]) async {
        guard let doc = pdfDocument else { return }

        await MainActor.run {
            isProcessing = true
            progress = 0
        }

        let total = pageIndices.count

        for (processed, pageIndex) in pageIndices.enumerated() {
            guard let page = doc.page(at: pageIndex) else { continue }

            do {
                let text = try await recognizeText(on: page, pageIndex: pageIndex)

                await MainActor.run {
                    recognizedText[pageIndex] = text
                    recognizedPages.insert(pageIndex)

                    if !page.hasText && !text.isEmpty {
                        addTextOverlay(text: text, to: page)
                    }

                    progress = Double(processed + 1) / Double(total)
                }
            } catch {
                await MainActor.run {
                    progress = Double(processed + 1) / Double(total)
                }
            }
        }

        await MainActor.run {
            isProcessing = false
            progress = 1.0
            if !recognizedPages.isEmpty {
                parent?.markDocumentEdited()
            }
        }
    }

    // MARK: - Text Recognition

    private func recognizeText(on page: PDFPage, pageIndex: Int) async throws -> String {
        guard let cgImage = page.renderToCGImage(dpi: PDFDefaults.ocrDPI) else {
            throw OakReaderError.ocrFailed(page: pageIndex, underlying: nil)
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OakReaderError.ocrFailed(page: pageIndex, underlying: error))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }

                let text = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }.joined(separator: "\n")

                continuation.resume(returning: text)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            // Set recognition languages
            let supportedLanguages: [String]
            do {
                supportedLanguages = try request.supportedRecognitionLanguages()
            } catch {
                supportedLanguages = ["en-US"]
            }

            if supportedLanguages.contains(where: { $0.hasPrefix(language) }) {
                request.recognitionLanguages = [language]
            } else {
                request.recognitionLanguages = ["en-US"]
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: OakReaderError.ocrFailed(page: pageIndex, underlying: error))
            }
        }
    }

    // MARK: - Text Overlay

    private func addTextOverlay(text: String, to page: PDFPage) {
        let pageRect = page.bounds(for: .mediaBox)

        // Create an invisible freeText annotation containing the recognized text
        // This makes the text searchable and selectable
        let annotation = PDFAnnotation(bounds: pageRect, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font = NSFont(name: "Helvetica", size: 1)  // Tiny invisible font
        annotation.fontColor = .clear
        annotation.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        page.addAnnotation(annotation)
    }

    // MARK: - Computed Properties

    var progressLabel: String {
        guard isProcessing else { return "" }
        return "Processing... \(Int(progress * 100))%"
    }

    var resultSummary: String {
        let total = pdfDocument?.pageCount ?? 0
        let recognized = recognizedPages.count
        return "\(recognized) of \(total) pages recognized"
    }

    func recognizedTextForPage(_ pageIndex: Int) -> String? {
        recognizedText[pageIndex]
    }

    func setLanguage(_ code: String) {
        language = code
        Preferences.shared.ocrLanguage = code
    }
}
