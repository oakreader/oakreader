import Foundation
import PDFKit
import AppKit

@Observable
class HeaderFooterViewModel {
    weak var parent: DocumentViewModel?

    var config: HeaderFooterConfig = HeaderFooterConfig()
    var isApplying: Bool = false
    var isPreviewVisible: Bool = false

    init(parent: DocumentViewModel) {
        self.parent = parent
    }

    private var pdfDocument: PDFDocument? { parent?.pdfDocument }

    // MARK: - Configuration

    func setHeaderLeft(_ text: String) { config.headerLeft = text }
    func setHeaderCenter(_ text: String) { config.headerCenter = text }
    func setHeaderRight(_ text: String) { config.headerRight = text }
    func setFooterLeft(_ text: String) { config.footerLeft = text }
    func setFooterCenter(_ text: String) { config.footerCenter = text }
    func setFooterRight(_ text: String) { config.footerRight = text }

    func setFontName(_ name: String) { config.fontName = name }
    func setFontSize(_ size: CGFloat) { config.fontSize = max(4, min(36, size)) }
    func setColor(_ color: NSColor) { config.color = color }

    func setMargins(top: CGFloat? = nil, bottom: CGFloat? = nil, left: CGFloat? = nil, right: CGFloat? = nil) {
        if let top { config.margins.top = max(0, top) }
        if let bottom { config.margins.bottom = max(0, bottom) }
        if let left { config.margins.left = max(0, left) }
        if let right { config.margins.right = max(0, right) }
    }

    func setPageRange(_ range: PageRange) { config.pageRange = range }
    func setStartPageNumber(_ number: Int) { config.startPageNumber = max(1, number) }

    // MARK: - Bates Numbering

    func enableBatesNumbering(_ enabled: Bool) {
        config.useBatesNumbering = enabled
    }

    func setBatesPrefix(_ prefix: String) { config.batesPrefix = prefix }
    func setBatesSuffix(_ suffix: String) { config.batesSuffix = suffix }
    func setBatesStartNumber(_ number: Int) { config.batesStartNumber = max(0, number) }
    func setBatesDigits(_ digits: Int) { config.batesDigits = max(1, min(12, digits)) }

    // MARK: - Preview

    func togglePreview() {
        isPreviewVisible.toggle()
    }

    func generatePreview(for pageIndex: Int) -> NSImage? {
        guard let doc = pdfDocument,
              let page = doc.page(at: pageIndex) else { return nil }

        let pageRect = page.bounds(for: .mediaBox)
        let image = NSImage(size: pageRect.size)
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }

        // Draw the page
        page.draw(with: .mediaBox, to: context)

        // Draw headers and footers
        drawHeaderFooter(in: context, pageRect: pageRect, pageIndex: pageIndex, totalPages: doc.pageCount)

        image.unlockFocus()
        return image
    }

    // MARK: - Apply

    func apply(to document: PDFDocument? = nil) async {
        let targetDoc = document ?? pdfDocument
        guard let doc = targetDoc else { return }

        await MainActor.run {
            isApplying = true
        }

        let tempURL = FileCoordination.temporaryURL()
        let localConfig = config
        let totalPages = doc.pageCount

        do {
            try PDFRewriter.rewriteDocument(doc, to: tempURL) { page, pageIndex, context in
                guard localConfig.pageRange.contains(pageIndex) else { return }

                let pageRect = page.bounds(for: .mediaBox)
                let font = NSFont(name: localConfig.fontName, size: localConfig.fontSize)
                    ?? NSFont.systemFont(ofSize: localConfig.fontSize)

                let headerY = pageRect.maxY - localConfig.margins.top
                let footerY = localConfig.margins.bottom

                // Headers
                let hLeft = localConfig.resolvedText(localConfig.headerLeft, pageIndex: pageIndex, totalPages: totalPages)
                let hCenter = localConfig.resolvedText(localConfig.headerCenter, pageIndex: pageIndex, totalPages: totalPages)
                let hRight = localConfig.resolvedText(localConfig.headerRight, pageIndex: pageIndex, totalPages: totalPages)

                if !hLeft.isEmpty {
                    context.drawText(hLeft, at: CGPoint(x: localConfig.margins.left, y: headerY), font: font, color: localConfig.color)
                }
                if !hCenter.isEmpty {
                    context.drawCenteredText(hCenter, in: CGRect(x: 0, y: headerY - localConfig.fontSize, width: pageRect.width, height: localConfig.fontSize * 1.5), font: font, color: localConfig.color)
                }
                if !hRight.isEmpty {
                    let attrs: [NSAttributedString.Key: Any] = [.font: font]
                    let textWidth = (hRight as NSString).size(withAttributes: attrs).width
                    context.drawText(hRight, at: CGPoint(x: pageRect.width - localConfig.margins.right - textWidth, y: headerY), font: font, color: localConfig.color)
                }

                // Footers
                let fLeft = localConfig.resolvedText(localConfig.footerLeft, pageIndex: pageIndex, totalPages: totalPages)
                let fCenter = localConfig.resolvedText(localConfig.footerCenter, pageIndex: pageIndex, totalPages: totalPages)
                let fRight = localConfig.resolvedText(localConfig.footerRight, pageIndex: pageIndex, totalPages: totalPages)

                if !fLeft.isEmpty {
                    context.drawText(fLeft, at: CGPoint(x: localConfig.margins.left, y: footerY), font: font, color: localConfig.color)
                }
                if !fCenter.isEmpty {
                    context.drawCenteredText(fCenter, in: CGRect(x: 0, y: footerY - localConfig.fontSize / 2, width: pageRect.width, height: localConfig.fontSize * 1.5), font: font, color: localConfig.color)
                }
                if !fRight.isEmpty {
                    let attrs: [NSAttributedString.Key: Any] = [.font: font]
                    let textWidth = (fRight as NSString).size(withAttributes: attrs).width
                    context.drawText(fRight, at: CGPoint(x: pageRect.width - localConfig.margins.right - textWidth, y: footerY), font: font, color: localConfig.color)
                }
            }

            guard let resultDoc = PDFDocument(url: tempURL) else {
                throw OakReaderError.fileWriteFailed(tempURL, underlying: nil)
            }

            await MainActor.run {
                // Replace pages with header/footer versions
                let pageCount = doc.pageCount
                for i in 0..<min(pageCount, resultDoc.pageCount) {
                    guard let newPage = resultDoc.page(at: i),
                          let copied = newPage.copy() as? PDFPage else { continue }
                    doc.removePage(at: i)
                    doc.insert(copied, at: i)
                }

                isApplying = false
                if document == nil {
                    parent?.markDocumentEdited()
                }
            }

            try? FileManager.default.removeItem(at: tempURL)

        } catch {
            await MainActor.run {
                isApplying = false
                parent?.state.presentError("Failed to apply header/footer: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Drawing Helper

    private func drawHeaderFooter(in context: CGContext, pageRect: CGRect, pageIndex: Int, totalPages: Int) {
        let font = NSFont(name: config.fontName, size: config.fontSize)
            ?? NSFont.systemFont(ofSize: config.fontSize)

        let headerY = pageRect.maxY - config.margins.top
        let footerY = config.margins.bottom

        // Headers
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

        // Footers
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
    }

    // MARK: - Presets

    func applyPageNumbersOnly() {
        config = HeaderFooterConfig()
        config.footerCenter = "<<page>> of <<total>>"
    }

    func applyBatesNumbering(prefix: String = "", startNumber: Int = 1, digits: Int = 6) {
        config = HeaderFooterConfig()
        config.useBatesNumbering = true
        config.batesPrefix = prefix
        config.batesStartNumber = startNumber
        config.batesDigits = digits
        config.footerLeft = "<<bates>>"
    }

    func applyConfidentialHeader() {
        config.headerCenter = "CONFIDENTIAL"
        config.color = .systemRed
    }

    // MARK: - Reset

    func reset() {
        config = HeaderFooterConfig()
        isPreviewVisible = false
    }

    // MARK: - Template Variables Help

    static let templateVariables: [(variable: String, description: String)] = [
        ("<<page>>", "Current page number"),
        ("<<total>>", "Total number of pages"),
        ("<<date>>", "Current date"),
        ("<<bates>>", "Bates number (when enabled)"),
    ]
}
