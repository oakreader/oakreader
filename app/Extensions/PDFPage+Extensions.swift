import PDFKit
import AppKit
import CoreGraphics

extension PDFPage {
    var pageSize: CGSize {
        bounds(for: .mediaBox).size
    }

    func renderToImage(dpi: CGFloat = 150) -> NSImage? {
        let pageRect = bounds(for: .mediaBox)
        let scale = dpi / 72.0
        let width = pageRect.width * scale
        let height = pageRect.height * scale
        let imageSize = CGSize(width: width, height: height)

        let image = NSImage(size: imageSize)
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: imageSize))
        context.scaleBy(x: scale, y: scale)

        draw(with: .mediaBox, to: context)

        image.unlockFocus()
        return image
    }

    func renderToCGImage(dpi: CGFloat = 150) -> CGImage? {
        let pageRect = bounds(for: .mediaBox)
        let scale = dpi / 72.0
        let width = Int(pageRect.width * scale)
        let height = Int(pageRect.height * scale)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)

        draw(with: .mediaBox, to: context)

        return context.makeImage()
    }

    /// Retina-aware thumbnail: renders at 2x pixel density for sharp display
    func thumbnail(maxDimension: CGFloat = 160) -> NSImage {
        let pageRect = bounds(for: .mediaBox)
        let fitScale = min(maxDimension / pageRect.width, maxDimension / pageRect.height)
        let displaySize = CGSize(
            width: pageRect.width * fitScale,
            height: pageRect.height * fitScale
        )

        // Render at 2x for Retina
        let pixelScale: CGFloat = 2.0
        let pixelWidth = Int(displaySize.width * pixelScale)
        let pixelHeight = Int(displaySize.height * pixelScale)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: pixelWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return thumbnail(of: displaySize, for: .mediaBox)
        }

        // Force light appearance so thumbnails always render with original page colors
        let savedAppearance = NSAppearance.current
        NSAppearance.current = NSAppearance(named: .aqua)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: fitScale * pixelScale, y: fitScale * pixelScale)
        draw(with: .mediaBox, to: context)
        NSAppearance.current = savedAppearance

        guard let cgImage = context.makeImage() else {
            return thumbnail(of: displaySize, for: .mediaBox)
        }

        // Set NSImage size to display points so AppKit uses the extra pixels for Retina
        let image = NSImage(cgImage: cgImage, size: displaySize)
        return image
    }

    func annotationsOfType(_ type: String) -> [PDFAnnotation] {
        annotations.filter { $0.type == type }
    }

    func removeAllAnnotations() {
        let toRemove = annotations
        for annotation in toRemove {
            removeAnnotation(annotation)
        }
    }

    var hasText: Bool {
        !(string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func blankPage(size: CGSize = PDFDefaults.defaultPageSize) -> PDFPage {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return PDFPage()
        }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        guard let provider = CGDataProvider(data: data as CFData),
              let cgDoc = CGPDFDocument(provider),
              let cgPage = cgDoc.page(at: 1) else {
            return PDFPage()
        }
        guard let blankDoc = PDFDocument(data: data as Data),
              let blankPage = blankDoc.page(at: 0) else {
            return PDFPage()
        }
        return blankPage
    }
}
