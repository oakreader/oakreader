import Foundation
import PDFKit
import AppKit
import CoreGraphics

struct PDFRenderingService {

    func renderPage(_ page: PDFPage, dpi: CGFloat = 150) -> CGImage? {
        let pageRect = page.bounds(for: .mediaBox)
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
        context.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)

        // Draw only the page content (without annotations)
        if let cgPage = page.pageRef {
            context.drawPDFPage(cgPage)
        }

        return context.makeImage()
    }

    func renderPageWithAnnotations(_ page: PDFPage, dpi: CGFloat = 150) -> CGImage? {
        let pageRect = page.bounds(for: .mediaBox)
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

        // draw(with:to:) renders both page content and annotations
        page.draw(with: .mediaBox, to: context)

        return context.makeImage()
    }

    func renderPageToNSImage(_ page: PDFPage, dpi: CGFloat = 150) -> NSImage? {
        page.renderToImage(dpi: dpi)
    }

    func renderThumbnail(_ page: PDFPage, maxDimension: CGFloat = 160) -> NSImage {
        page.thumbnail(maxDimension: maxDimension)
    }

    func renderPageRegion(
        _ page: PDFPage,
        region: CGRect,
        dpi: CGFloat = 150
    ) -> CGImage? {
        let scale = dpi / 72.0
        let width = Int(region.width * scale)
        let height = Int(region.height * scale)

        guard width > 0, height > 0 else { return nil }

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

        // Translate so the region origin aligns with the context origin
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -region.origin.x, y: -region.origin.y)

        page.draw(with: .mediaBox, to: context)

        return context.makeImage()
    }
}
