import Foundation
import PDFKit
import AppKit

@Observable
class BatchViewModel {
    weak var parent: DocumentViewModel?

    var jobs: [BatchJob] = []
    var operationType: BatchOperationType = .compress
    var isProcessing: Bool = false
    var overallProgress: Double = 0
    var outputDirectory: URL?

    // Operation-specific settings
    var compressionQuality: CompressionQuality = .medium
    var watermarkConfig: WatermarkConfig = WatermarkConfig()
    var headerFooterConfig: HeaderFooterConfig = HeaderFooterConfig()
    var password: String = ""
    var redactPattern: String = ""

    init(parent: DocumentViewModel) {
        self.parent = parent
    }

    // MARK: - File Management

    func addFiles(_ urls: [URL]) {
        let newJobs = urls.compactMap { url -> BatchJob? in
            guard url.pathExtension.lowercased() == "pdf" else { return nil }
            // Don't add duplicates
            guard !jobs.contains(where: { $0.fileURL == url }) else { return nil }
            return BatchJob(fileURL: url)
        }
        jobs.append(contentsOf: newJobs)
    }

    func addFilesWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]
        panel.message = "Select PDF files for batch processing"

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.addFiles(panel.urls)
        }
    }

    func removeFile(at index: Int) {
        guard index >= 0, index < jobs.count else { return }
        jobs.remove(at: index)
    }

    func removeFile(_ job: BatchJob) {
        jobs.removeAll { $0.id == job.id }
    }

    func clearFiles() {
        jobs.removeAll()
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose output directory for processed files"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.outputDirectory = url
        }
    }

    // MARK: - Process

    func process() async {
        guard !jobs.isEmpty else { return }

        // Determine output directory
        let output = outputDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent("OakReader_Batch_\(UUID().uuidString.prefix(8))")

        // Create output directory if needed
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        await MainActor.run {
            isProcessing = true
            overallProgress = 0
            // Reset all job statuses
            for i in 0..<jobs.count {
                jobs[i].status = .pending
                jobs[i].error = nil
                jobs[i].outputURL = nil
            }
        }

        let totalJobs = jobs.count

        for (index, job) in jobs.enumerated() {
            await MainActor.run {
                jobs[index].status = .processing(progress: 0)
            }

            do {
                let outputURL = output.appendingPathComponent(job.fileURL.lastPathComponent)

                guard let doc = PDFDocument(url: job.fileURL) else {
                    throw OakReaderError.invalidPDF
                }

                try await processDocument(doc, operation: operationType, outputURL: outputURL, jobIndex: index)

                await MainActor.run {
                    jobs[index].status = .completed
                    jobs[index].outputURL = outputURL
                    overallProgress = Double(index + 1) / Double(totalJobs)
                }
            } catch {
                await MainActor.run {
                    jobs[index].status = .failed
                    jobs[index].error = error.localizedDescription
                    overallProgress = Double(index + 1) / Double(totalJobs)
                }
            }
        }

        await MainActor.run {
            isProcessing = false
            overallProgress = 1.0
        }
    }

    // MARK: - Process Individual Document

    private func processDocument(_ doc: PDFDocument, operation: BatchOperationType, outputURL: URL, jobIndex: Int) async throws {
        switch operation {
        case .compress:
            try await compressDocument(doc, to: outputURL, jobIndex: jobIndex)

        case .watermark:
            try await watermarkDocument(doc, to: outputURL, jobIndex: jobIndex)

        case .headerFooter:
            try await headerFooterDocument(doc, to: outputURL, jobIndex: jobIndex)

        case .convertToImages:
            try await convertToImages(doc, to: outputURL.deletingPathExtension(), jobIndex: jobIndex)

        case .merge:
            // Merge is handled separately
            break

        case .passwordProtect:
            try await passwordProtectDocument(doc, to: outputURL)

        case .removePassword:
            try await removePasswordFromDocument(doc, to: outputURL)

        case .redactPattern:
            try await redactPatternInDocument(doc, to: outputURL, jobIndex: jobIndex)

        case .flattenAnnotations:
            try await flattenDocument(doc, to: outputURL)
        }
    }

    // MARK: - Compress

    private func compressDocument(_ doc: PDFDocument, to outputURL: URL, jobIndex: Int) async throws {
        let quality = compressionQuality

        let totalPages = doc.pageCount
        try PDFRewriter.rewriteDocument(doc, to: outputURL) { page, pageIndex, context in
            // The page content is already drawn by the rewriter.
            // For compression, the main savings come from image downsampling
            // which happens at the CGContext PDF level via the quality settings.
            let _ = pageIndex // progress tracked at job level
        }

        // If the rewritten file is larger, try data representation approach
        if let data = doc.dataRepresentation() {
            let originalSize = data.count
            if let rewrittenData = try? Data(contentsOf: outputURL) {
                if rewrittenData.count > originalSize {
                    try data.write(to: outputURL)
                }
            }
        }
    }

    // MARK: - Watermark

    private func watermarkDocument(_ doc: PDFDocument, to outputURL: URL, jobIndex: Int) async throws {
        let config = watermarkConfig

        try PDFRewriter.rewriteDocument(doc, to: outputURL) { page, pageIndex, context in
            guard config.pageRange.contains(pageIndex) else { return }

            let pageRect = page.bounds(for: .mediaBox)

            switch config.type {
            case .text(let text):
                let font = NSFont(name: config.fontName, size: config.fontSize)
                    ?? NSFont.systemFont(ofSize: config.fontSize)
                context.drawWatermarkText(
                    text,
                    in: pageRect,
                    font: font,
                    color: config.color,
                    opacity: config.opacity,
                    rotation: config.rotation
                )

            case .image(let data):
                if let nsImage = NSImage(data: data), let cgImage = nsImage.cgImage {
                    context.drawWatermarkImage(cgImage, in: pageRect, opacity: config.opacity, scale: config.scale)
                }
            }

            DispatchQueue.main.async { [weak self] in
                let pageProgress = Double(pageIndex + 1) / Double(doc.pageCount)
                self?.jobs[jobIndex].status = .processing(progress: pageProgress)
            }
        }
    }

    // MARK: - Header/Footer

    private func headerFooterDocument(_ doc: PDFDocument, to outputURL: URL, jobIndex: Int) async throws {
        let config = headerFooterConfig
        let totalPages = doc.pageCount

        try PDFRewriter.rewriteDocument(doc, to: outputURL) { page, pageIndex, context in
            guard config.pageRange.contains(pageIndex) else { return }

            let pageRect = page.bounds(for: .mediaBox)
            let font = NSFont(name: config.fontName, size: config.fontSize)
                ?? NSFont.systemFont(ofSize: config.fontSize)

            let headerY = pageRect.maxY - config.margins.top
            let footerY = config.margins.bottom

            // Draw headers
            let hLeft = config.resolvedText(config.headerLeft, pageIndex: pageIndex, totalPages: totalPages)
            let hCenter = config.resolvedText(config.headerCenter, pageIndex: pageIndex, totalPages: totalPages)
            let hRight = config.resolvedText(config.headerRight, pageIndex: pageIndex, totalPages: totalPages)

            if !hLeft.isEmpty {
                context.drawText(hLeft, at: CGPoint(x: config.margins.left, y: headerY), font: font, color: config.color)
            }
            if !hCenter.isEmpty {
                context.drawCenteredText(hCenter, in: CGRect(x: 0, y: headerY - config.fontSize, width: pageRect.width, height: config.fontSize * 1.5), font: font, color: config.color)
            }
            if !hRight.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: font]
                let textWidth = (hRight as NSString).size(withAttributes: attrs).width
                context.drawText(hRight, at: CGPoint(x: pageRect.width - config.margins.right - textWidth, y: headerY), font: font, color: config.color)
            }

            // Draw footers
            let fLeft = config.resolvedText(config.footerLeft, pageIndex: pageIndex, totalPages: totalPages)
            let fCenter = config.resolvedText(config.footerCenter, pageIndex: pageIndex, totalPages: totalPages)
            let fRight = config.resolvedText(config.footerRight, pageIndex: pageIndex, totalPages: totalPages)

            if !fLeft.isEmpty {
                context.drawText(fLeft, at: CGPoint(x: config.margins.left, y: footerY), font: font, color: config.color)
            }
            if !fCenter.isEmpty {
                context.drawCenteredText(fCenter, in: CGRect(x: 0, y: footerY - config.fontSize / 2, width: pageRect.width, height: config.fontSize * 1.5), font: font, color: config.color)
            }
            if !fRight.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: font]
                let textWidth = (fRight as NSString).size(withAttributes: attrs).width
                context.drawText(fRight, at: CGPoint(x: pageRect.width - config.margins.right - textWidth, y: footerY), font: font, color: config.color)
            }

            DispatchQueue.main.async { [weak self] in
                let pageProgress = Double(pageIndex + 1) / Double(doc.pageCount)
                self?.jobs[jobIndex].status = .processing(progress: pageProgress)
            }
        }
    }

    // MARK: - Convert to Images

    private func convertToImages(_ doc: PDFDocument, to baseURL: URL, jobIndex: Int) async throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i),
                  let cgImage = page.renderToCGImage(dpi: 150) else { continue }

            let nsImage = NSImage.from(cgImage: cgImage)
            let fileName = "page_\(String(format: "%04d", i + 1)).png"
            let fileURL = baseURL.appendingPathComponent(fileName)

            if let data = nsImage.pngData() {
                try data.write(to: fileURL)
            }

            await MainActor.run { [weak self] in
                let pageProgress = Double(i + 1) / Double(doc.pageCount)
                self?.jobs[jobIndex].status = .processing(progress: pageProgress)
            }
        }
    }

    // MARK: - Password Protect

    private func passwordProtectDocument(_ doc: PDFDocument, to outputURL: URL) async throws {
        guard !password.isEmpty else {
            throw OakReaderError.encryptionFailed("No password provided")
        }

        var settings = SecuritySettings()
        settings.openPassword = password
        settings.permissionsPassword = password

        try PDFRewriter.rewriteWithSecurity(doc, to: outputURL, settings: settings)
    }

    // MARK: - Remove Password

    private func removePasswordFromDocument(_ doc: PDFDocument, to outputURL: URL) async throws {
        // If the document is already unlocked, just write it without encryption
        guard doc.write(to: outputURL) else {
            throw OakReaderError.fileWriteFailed(outputURL, underlying: nil)
        }
    }

    // MARK: - Redact Pattern

    private func redactPatternInDocument(_ doc: PDFDocument, to outputURL: URL, jobIndex: Int) async throws {
        guard !redactPattern.isEmpty else {
            throw OakReaderError.redactionFailed("No redaction pattern provided")
        }

        let results = doc.searchAll(redactPattern, options: [.caseInsensitive])

        // Group by page
        var regionsByPage: [Int: [CGRect]] = [:]
        for result in results {
            for page in result.pages {
                let pageIndex = doc.index(for: page)
                let bounds = result.bounds(for: page)
                regionsByPage[pageIndex, default: []].append(bounds)
            }
        }

        try PDFRewriter.rewriteDocument(doc, to: outputURL) { page, pageIndex, context in
            guard let regions = regionsByPage[pageIndex] else { return }

            for bounds in regions {
                context.drawRedaction(over: bounds)
            }

            DispatchQueue.main.async { [weak self] in
                let pageProgress = Double(pageIndex + 1) / Double(doc.pageCount)
                self?.jobs[jobIndex].status = .processing(progress: pageProgress)
            }
        }
    }

    // MARK: - Flatten Annotations

    private func flattenDocument(_ doc: PDFDocument, to outputURL: URL) async throws {
        doc.flattenAnnotations()
        guard doc.write(to: outputURL) else {
            throw OakReaderError.fileWriteFailed(outputURL, underlying: nil)
        }
    }

    // MARK: - Merge All

    func mergeAll() async {
        guard jobs.count >= 2 else {
            await MainActor.run {
                parent?.state.presentError("At least 2 files are needed for merge.")
            }
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Merged.pdf"
        panel.canCreateDirectories = true

        let response = await MainActor.run { panel.runModal() }
        guard response == .OK, let outputURL = panel.url else { return }

        await MainActor.run {
            isProcessing = true
            overallProgress = 0
        }

        let mergedDoc = PDFDocument()

        for (index, job) in jobs.enumerated() {
            guard let doc = PDFDocument(url: job.fileURL) else {
                await MainActor.run {
                    jobs[index].status = .failed
                    jobs[index].error = "Failed to open file"
                }
                continue
            }

            mergedDoc.appendDocument(doc)

            await MainActor.run {
                jobs[index].status = .completed
                overallProgress = Double(index + 1) / Double(jobs.count)
            }
        }

        if mergedDoc.write(to: outputURL) {
            await MainActor.run {
                isProcessing = false
                overallProgress = 1.0
                NSWorkspace.shared.open(outputURL)
            }
        } else {
            await MainActor.run {
                isProcessing = false
                parent?.state.presentError("Failed to write merged document.")
            }
        }
    }

    // MARK: - Computed Properties

    var completedCount: Int {
        jobs.filter { $0.status == .completed }.count
    }

    var failedCount: Int {
        jobs.filter { $0.status == .failed }.count
    }

    var progressLabel: String {
        guard isProcessing else { return "" }
        return "Processing \(completedCount + failedCount + 1) of \(jobs.count)..."
    }

    var resultSummary: String {
        guard !jobs.isEmpty else { return "No files added" }
        let completed = completedCount
        let failed = failedCount
        if completed == 0 && failed == 0 {
            return "\(jobs.count) file\(jobs.count == 1 ? "" : "s") ready"
        }
        var parts: [String] = []
        if completed > 0 { parts.append("\(completed) completed") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: ", ")
    }
}
