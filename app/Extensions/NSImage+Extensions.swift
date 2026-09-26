import AppKit
import CoreGraphics

extension NSImage {
    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func jpegData(quality: CGFloat = 0.8) -> Data? {
        guard let tiffData = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    func tiffData(compression: NSBitmapImageRep.TIFFCompression = .lzw) -> Data? {
        guard let tiffData = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData) else { return nil }
        return rep.representation(using: .tiff, properties: [.compressionMethod: compression.rawValue])
    }

    func resized(to targetSize: CGSize) -> NSImage {
        let newImage = NSImage(size: targetSize)
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: CGRect(origin: .zero, size: targetSize),
             from: CGRect(origin: .zero, size: size),
             operation: .copy,
             fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }

    func resizedToFit(maxDimension: CGFloat) -> NSImage {
        let ratio = min(maxDimension / size.width, maxDimension / size.height)
        if ratio >= 1.0 { return self }
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        return resized(to: newSize)
    }

    static func from(cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: CGSize(width: cgImage.width, height: cgImage.height))
    }

    func toPDFPage() -> PDFPage? {
        guard let cgImage = self.cgImage else { return nil }
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        context.beginPDFPage(nil)
        context.draw(cgImage, in: mediaBox)
        context.endPDFPage()
        context.closePDF()

        guard let provider = CGDataProvider(data: data as CFData),
              let pdfDoc = CGPDFDocument(provider),
              let pdfPage = pdfDoc.page(at: 1) else { return nil }

        guard let pdfDoc2 = PDFDocument(data: data as Data),
              let resultPage = pdfDoc2.page(at: 0) else { return nil }
        return resultPage
    }
}

import PDFKit
