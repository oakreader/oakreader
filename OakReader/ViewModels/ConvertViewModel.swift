import Foundation
import PDFKit
import AppKit
import UniformTypeIdentifiers

@Observable
class ConvertViewModel {
    weak var parent: DocumentViewModel?

    var isExporting: Bool = false
    var isImporting: Bool = false
    var exportProgress: Double = 0
    var exportFormat: ExportImageFormat = .png
    var exportDPI: CGFloat = 150
    var exportPageRange: PageRange = .all

    enum ExportImageFormat: String, CaseIterable, Identifiable {
        case png
        case jpeg
        case tiff

        var id: String { rawValue }

        var label: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            case .tiff: return "TIFF"
            }
        }

        var fileExtension: String { rawValue }

        var utType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .tiff: return .tiff
            }
        }
    }

    init(parent: DocumentViewModel) {
        self.parent = parent
    }

    private var pdfDocument: PDFDocument? { parent?.pdfDocument }

    // MARK: - Export as Images

    func exportAsImages(pages pageIndices: [Int]? = nil, format: ExportImageFormat, dpi: CGFloat, to directory: URL) async {
        guard let doc = pdfDocument else { return }

        let indices = pageIndices ?? Array(0..<doc.pageCount)
        guard !indices.isEmpty else { return }

        await MainActor.run {
            isExporting = true
            exportProgress = 0
        }

        let total = indices.count
        var exportedCount = 0
        var errors: [String] = []

        for (i, pageIndex) in indices.enumerated() {
            guard let page = doc.page(at: pageIndex) else { continue }

            let fileName = "page_\(String(format: "%04d", pageIndex + 1)).\(format.fileExtension)"
            let fileURL = directory.appendingPathComponent(fileName)

            guard let cgImage = page.renderToCGImage(dpi: dpi) else {
                errors.append("Failed to render page \(pageIndex + 1)")
                continue
            }

            let nsImage = NSImage.from(cgImage: cgImage)
            var imageData: Data?

            switch format {
            case .png:
                imageData = nsImage.pngData()
            case .jpeg:
                imageData = nsImage.jpegData(quality: 0.9)
            case .tiff:
                imageData = nsImage.tiffData()
            }

            if let data = imageData {
                do {
                    try data.write(to: fileURL)
                    exportedCount += 1
                } catch {
                    errors.append("Failed to write page \(pageIndex + 1): \(error.localizedDescription)")
                }
            } else {
                errors.append("Failed to encode page \(pageIndex + 1) as \(format.label)")
            }

            await MainActor.run {
                exportProgress = Double(i + 1) / Double(total)
            }
        }

        let finalErrors = errors
        let finalExportedCount = exportedCount
        await MainActor.run {
            isExporting = false
            exportProgress = 1.0

            if !finalErrors.isEmpty {
                parent?.state.presentError(finalErrors.joined(separator: "\n"))
            }

            // Open the output directory in Finder
            if finalExportedCount > 0 {
                NSWorkspace.shared.open(directory)
            }
        }
    }

    func exportAsImagesWithPanel(format: ExportImageFormat? = nil, dpi: CGFloat? = nil) async {
        let url: URL? = await MainActor.run {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.message = "Choose a folder to save the exported images"
            panel.prompt = "Export"
            let response = panel.runModal()
            return response == .OK ? panel.url : nil
        }
        guard let url else { return }

        let resolvedFormat = format ?? exportFormat
        let resolvedDPI = dpi ?? exportDPI

        let indices: [Int]?
        switch exportPageRange {
        case .all:
            indices = nil
        case .range(let range):
            indices = Array(range)
        case .custom(let pages):
            indices = pages
        }

        await exportAsImages(pages: indices, format: resolvedFormat, dpi: resolvedDPI, to: url)
    }

    // MARK: - Export as Text (DOCX-like plain text)

    func exportAsDocx(to url: URL) async {
        guard let doc = pdfDocument else { return }

        await MainActor.run {
            isExporting = true
            exportProgress = 0
        }

        var textContent = ""
        let totalPages = doc.pageCount

        for i in 0..<totalPages {
            guard let page = doc.page(at: i) else { continue }
            let pageText = page.string ?? ""

            textContent += "--- Page \(i + 1) ---\n"
            textContent += pageText
            textContent += "\n\n"

            await MainActor.run {
                exportProgress = Double(i + 1) / Double(totalPages)
            }
        }

        do {
            // Export as RTF for basic formatting support
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)
            ]
            let attrString = NSAttributedString(string: textContent, attributes: attrs)
            let rtfData = try attrString.data(
                from: NSRange(location: 0, length: attrString.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            try rtfData.write(to: url)

            await MainActor.run {
                isExporting = false
                exportProgress = 1.0
                NSWorkspace.shared.open(url)
            }
        } catch {
            await MainActor.run {
                isExporting = false
                parent?.state.presentError("Export failed: \(error.localizedDescription)")
            }
        }
    }

    func exportAsDocxWithPanel() async {
        let url: URL? = await MainActor.run {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType.rtf]
            panel.nameFieldStringValue = "Exported Document.rtf"
            panel.canCreateDirectories = true
            let response = panel.runModal()
            return response == .OK ? panel.url : nil
        }
        guard let url else { return }

        await exportAsDocx(to: url)
    }

    // MARK: - Import Images

    func importImages(_ urls: [URL]) {
        guard let doc = pdfDocument else { return }

        var insertedCount = 0
        for url in urls {
            guard let image = NSImage(contentsOf: url),
                  let page = image.toPDFPage() else {
                continue
            }
            doc.insert(page, at: doc.pageCount)
            insertedCount += 1
        }

        if insertedCount > 0 {
            parent?.markDocumentEdited()
        } else if !urls.isEmpty {
            parent?.state.presentError("Failed to import images. The files may not be valid image formats.")
        }
    }

    func importImagesWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .bmp, .gif]
        panel.message = "Select images to import as PDF pages"

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            self?.importImages(panel.urls)
        }
    }

    // MARK: - Export Single Page

    func exportPage(_ pageIndex: Int, format: ExportImageFormat, dpi: CGFloat, to url: URL) async throws {
        guard let doc = pdfDocument,
              let page = doc.page(at: pageIndex) else {
            throw OakReaderError.pageOutOfRange(index: pageIndex, count: pdfDocument?.pageCount ?? 0)
        }

        guard let cgImage = page.renderToCGImage(dpi: dpi) else {
            throw OakReaderError.exportFailed("Failed to render page \(pageIndex + 1)")
        }

        let nsImage = NSImage.from(cgImage: cgImage)
        let data: Data?

        switch format {
        case .png:
            data = nsImage.pngData()
        case .jpeg:
            data = nsImage.jpegData(quality: 0.9)
        case .tiff:
            data = nsImage.tiffData()
        }

        guard let imageData = data else {
            throw OakReaderError.exportFailed("Failed to encode page \(pageIndex + 1)")
        }

        try imageData.write(to: url)
    }

    // MARK: - Computed Properties

    var progressLabel: String {
        guard isExporting || isImporting else { return "" }
        return isExporting ? "Exporting... \(Int(exportProgress * 100))%" : "Importing..."
    }
}
