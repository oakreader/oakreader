import PDFKit
import AppKit
import CoreGraphics

extension PDFPage {
    /// Retina-aware thumbnail fitted inside a `maxDimension` square.
    ///
    /// Note this caps the page's **long** edge, so a portrait page comes back
    /// much narrower than `maxDimension`. Anywhere the result is drawn to a
    /// known width — a library cover in a card column — use
    /// `thumbnail(fittingWidth:)` instead, or the render starves the dimension
    /// that actually gets stretched.
    func thumbnail(maxDimension: CGFloat = 160) -> NSImage {
        renderThumbnail(fitScale: {
            let pageRect = bounds(for: .mediaBox)
            return min(maxDimension / pageRect.width, maxDimension / pageRect.height)
        }())
    }

    /// Retina-aware thumbnail rendered so its **width** lands on `width`,
    /// whatever the page's aspect. PDFs are vector, so this re-renders at the
    /// larger scale rather than upscaling pixels.
    func thumbnail(fittingWidth width: CGFloat) -> NSImage {
        renderThumbnail(fitScale: width / bounds(for: .mediaBox).width)
    }

    private func renderThumbnail(fitScale: CGFloat) -> NSImage {
        let pageRect = bounds(for: .mediaBox)
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
