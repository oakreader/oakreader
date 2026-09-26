import PDFKit
import AppKit
import CoreGraphics

extension PDFPage {
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

    var hasText: Bool {
        !(string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
