import Foundation
import PDFKit
import AppKit

actor BatchProcessingService {

    private let ocrService = OCRService()
    private let compressionService = CompressionService()
    private let watermarkService = WatermarkService()
    private let headerFooterService = HeaderFooterService()
    private let imageConversionService = ImageConversionService()
    private let mergeService = MergeService()
    private let securityService = SecurityService()
    private let redactionService = RedactionService()

    func process(
        files: [URL],
        operation: BatchOperationType,
        options: [String: Any] = [:],
        progressHandler: @Sendable (URL, Double) -> Void
    ) async throws -> [URL] {
        var outputURLs: [URL] = []

        for (index, fileURL) in files.enumerated() {
            let overallProgress = Double(index) / Double(files.count)
            progressHandler(fileURL, overallProgress)

            let outputURL = try await processFile(
                fileURL,
                operation: operation,
                options: options,
                progressHandler: { fileProgress in
                    let combined = (Double(index) + fileProgress) / Double(files.count)
                    progressHandler(fileURL, combined)
                }
            )
            outputURLs.append(outputURL)
        }

        return outputURLs
    }

    // MARK: - Single File Processing

    private func processFile(
        _ fileURL: URL,
        operation: BatchOperationType,
        options: [String: Any],
        progressHandler: @Sendable (Double) -> Void
    ) async throws -> URL {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw OakReaderError.fileNotFound(fileURL)
        }
        guard let document = PDFDocument(url: fileURL) else {
            throw OakReaderError.fileReadFailed(fileURL, underlying: nil)
        }

        let outputDir = fileURL.deletingLastPathComponent()
        let baseName = fileURL.deletingPathExtension().lastPathComponent

        switch operation {
        case .ocr:
            let language = options["language"] as? String ?? "en"
            let allPages = IndexSet(0..<document.pageCount)
            try await ocrService.ocrDocument(document, pages: allPages, progressHandler: progressHandler)
            let outputURL = outputDir.appendingPathComponent("\(baseName)_ocr.pdf")
            guard document.write(to: outputURL) else {
                throw OakReaderError.fileWriteFailed(outputURL, underlying: nil)
            }
            return outputURL

        case .compress:
            let qualityRaw = options["quality"] as? String ?? CompressionQuality.medium.rawValue
            let quality = CompressionQuality(rawValue: qualityRaw) ?? .medium
            let removeMetadata = options["removeMetadata"] as? Bool ?? false
            let (compressedData, _) = try await compressionService.compress(document, quality: quality, removeMetadata: removeMetadata)
            let outputURL = outputDir.appendingPathComponent("\(baseName)_compressed.pdf")
            try compressedData.write(to: outputURL)
            progressHandler(1.0)
            return outputURL

        case .watermark:
            let config = options["config"] as? WatermarkConfig ?? WatermarkConfig()
            try watermarkService.applyWatermark(config, to: document)
            let outputURL = outputDir.appendingPathComponent("\(baseName)_watermarked.pdf")
            guard document.write(to: outputURL) else {
                throw OakReaderError.fileWriteFailed(outputURL, underlying: nil)
            }
            progressHandler(1.0)
            return outputURL

        case .headerFooter:
            let config = options["config"] as? HeaderFooterConfig ?? HeaderFooterConfig()
            try headerFooterService.applyHeaderFooter(config, to: document)
            let outputURL = outputDir.appendingPathComponent("\(baseName)_hf.pdf")
            guard document.write(to: outputURL) else {
                throw OakReaderError.fileWriteFailed(outputURL, underlying: nil)
            }
            progressHandler(1.0)
            return outputURL

        case .convertToImages:
            let formatRaw = options["format"] as? String ?? ImageFormat.png.rawValue
            let format = ImageFormat(rawValue: formatRaw) ?? .png
            let dpi = options["dpi"] as? CGFloat ?? 150
            let imageDir = outputDir.appendingPathComponent("\(baseName)_images")
            try imageConversionService.exportAllPages(document, format: format, dpi: dpi, to: imageDir, progressHandler: progressHandler)
            return imageDir

        case .merge:
            // For merge, all files are merged into one; handle at the batch level
            let outputURL = outputDir.appendingPathComponent("\(baseName)_merged.pdf")
            guard document.write(to: outputURL) else {
                throw OakReaderError.fileWriteFailed(outputURL, underlying: nil)
            }
            progressHandler(1.0)
            return outputURL

        case .passwordProtect:
            let password = options["password"] as? String ?? ""
            var settings = SecuritySettings()
            settings.openPassword = password
            settings.permissionsPassword = options["ownerPassword"] as? String
            let outputURL = outputDir.appendingPathComponent("\(baseName)_encrypted.pdf")
            try securityService.applyEncryption(to: document, settings: settings, outputURL: outputURL)
            progressHandler(1.0)
            return outputURL

        case .removePassword:
            let password = options["password"] as? String ?? ""
            let outputURL = outputDir.appendingPathComponent("\(baseName)_unlocked.pdf")
            try securityService.removePassword(from: document, password: password, outputURL: outputURL)
            progressHandler(1.0)
            return outputURL

        case .redactPattern:
            let pattern = options["pattern"] as? String ?? ""
            guard !pattern.isEmpty else {
                throw OakReaderError.batchError("No redaction pattern specified.", fileURL: fileURL)
            }
            let regions = findPatternRegions(pattern, in: document)
            try redactionService.applyRedactions(regions, to: document)
            let outputURL = outputDir.appendingPathComponent("\(baseName)_redacted.pdf")
            guard document.write(to: outputURL) else {
                throw OakReaderError.fileWriteFailed(outputURL, underlying: nil)
            }
            progressHandler(1.0)
            return outputURL

        case .flattenAnnotations:
            document.flattenAnnotations()
            let outputURL = outputDir.appendingPathComponent("\(baseName)_flattened.pdf")
            guard document.write(to: outputURL) else {
                throw OakReaderError.fileWriteFailed(outputURL, underlying: nil)
            }
            progressHandler(1.0)
            return outputURL
        }
    }

    // MARK: - Merge All Files

    func mergeAll(files: [URL], outputURL: URL) throws -> URL {
        let merged = try mergeService.merge(urls: files)
        guard merged.write(to: outputURL) else {
            throw OakReaderError.fileWriteFailed(outputURL, underlying: nil)
        }
        return outputURL
    }

    // MARK: - Pattern-based Redaction Search

    private func findPatternRegions(_ pattern: String, in document: PDFDocument) -> [RedactionRegion] {
        var regions: [RedactionRegion] = []
        let selections = document.searchAll(pattern)

        for selection in selections {
            guard let page = selection.pages.first,
                  let pageIndex = selection.pages.first.flatMap({ document.index(for: $0) }) else { continue }

            let bounds = selection.bounds(for: page)
            let region = RedactionRegion(bounds: bounds, pageIndex: pageIndex)
            regions.append(region)
        }

        return regions
    }
}
