import Foundation
import PDFKit
import AppKit
import CoreGraphics

enum ImageFormat: String, CaseIterable, Identifiable {
    case jpeg
    case png
    case tiff

    var id: String { rawValue }

    var fileExtension: String { rawValue }

    var label: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .tiff: return "TIFF"
        }
    }
}

struct ImageConversionService {

    // MARK: - Page to Image Data

    func pageToImage(
        _ page: PDFPage,
        format: ImageFormat,
        dpi: CGFloat = 150
    ) throws -> Data {
        guard let nsImage = page.renderToImage(dpi: dpi) else {
            throw OakReaderError.conversionFailed(format: format.label, underlying: nil)
        }

        guard let tiffData = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData) else {
            throw OakReaderError.conversionFailed(format: format.label, underlying: nil)
        }

        let data: Data?
        switch format {
        case .jpeg:
            data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        case .png:
            data = rep.representation(using: .png, properties: [:])
        case .tiff:
            data = rep.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw.rawValue])
        }

        guard let imageData = data else {
            throw OakReaderError.conversionFailed(format: format.label, underlying: nil)
        }

        return imageData
    }

    // MARK: - Image to PDF Page

    func imageToPDFPage(_ image: NSImage) -> PDFPage? {
        image.toPDFPage()
    }

    // MARK: - Export All Pages

    func exportAllPages(
        _ document: PDFDocument,
        format: ImageFormat,
        dpi: CGFloat = 150,
        to directory: URL,
        progressHandler: (Double) -> Void
    ) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let total = document.pageCount
        guard total > 0 else { return }

        for i in 0..<total {
            guard let page = document.page(at: i) else { continue }

            let imageData = try pageToImage(page, format: format, dpi: dpi)
            let fileName = String(format: "page_%04d.%@", i + 1, format.fileExtension)
            let fileURL = directory.appendingPathComponent(fileName)
            try imageData.write(to: fileURL)

            progressHandler(Double(i + 1) / Double(total))
        }
    }

    // MARK: - Import images to document

    func imagesToDocument(_ images: [NSImage]) -> PDFDocument {
        let document = PDFDocument()
        for (index, image) in images.enumerated() {
            if let page = imageToPDFPage(image) {
                document.insert(page, at: index)
            }
        }
        return document
    }
}
