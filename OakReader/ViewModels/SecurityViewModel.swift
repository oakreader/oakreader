import Foundation
import PDFKit
import AppKit

@Observable
class SecurityViewModel {
    weak var parent: DocumentViewModel?

    var settings: SecuritySettings = SecuritySettings()
    var redactionRegions: [RedactionRegion] = []
    var isApplyingRedactions: Bool = false
    var redactionProgress: Double = 0

    init(parent: DocumentViewModel) {
        self.parent = parent
    }

    private var pdfDocument: PDFDocument? { parent?.pdfDocument }

    // MARK: - Password Management

    func setOpenPassword(_ password: String?) {
        if let password, password.isEmpty {
            settings.openPassword = nil
        } else {
            settings.openPassword = password
        }
        settings.isEncrypted = settings.needsEncryption
        parent?.markDocumentEdited()
    }

    func setPermissionsPassword(_ password: String?) {
        if let password, password.isEmpty {
            settings.permissionsPassword = nil
        } else {
            settings.permissionsPassword = password
        }
        settings.isEncrypted = settings.needsEncryption
        parent?.markDocumentEdited()
    }

    func removeAllPasswords() {
        settings.openPassword = nil
        settings.permissionsPassword = nil
        settings.isEncrypted = false
        parent?.markDocumentEdited()
    }

    // MARK: - Permission Settings

    func setAllowPrinting(_ allowed: Bool) {
        settings.allowPrinting = allowed
        parent?.markDocumentEdited()
    }

    func setAllowCopying(_ allowed: Bool) {
        settings.allowCopying = allowed
        parent?.markDocumentEdited()
    }

    func setAllowEditing(_ allowed: Bool) {
        settings.allowEditing = allowed
        parent?.markDocumentEdited()
    }

    func setAllowAnnotations(_ allowed: Bool) {
        settings.allowAnnotations = allowed
        parent?.markDocumentEdited()
    }

    func setEncryptionKeyLength(_ length: SecuritySettings.EncryptionKeyLength) {
        settings.encryptionKeyLength = length
        parent?.markDocumentEdited()
    }

    // MARK: - Redaction Marking

    func markForRedaction(_ bounds: CGRect, on pageIndex: Int) {
        guard let doc = pdfDocument,
              let page = doc.page(at: pageIndex) else { return }

        let region = RedactionRegion(bounds: bounds, pageIndex: pageIndex)
        redactionRegions.append(region)

        // Add a visual mark annotation showing the pending redaction
        let markAnnotation = region.createMarkAnnotation()
        page.addAnnotation(markAnnotation)
    }

    func markSelectionForRedaction(_ selection: PDFSelection) {
        guard let doc = pdfDocument else { return }

        for page in selection.pages {
            let pageIndex = doc.index(for: page)
            let bounds = selection.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            markForRedaction(bounds, on: pageIndex)
        }
    }

    func markPatternForRedaction(_ pattern: String) {
        guard let doc = pdfDocument else { return }

        // Security: validate regex to prevent ReDoS from malicious patterns
        do {
            _ = try NSRegularExpression(pattern: pattern)
        } catch {
            parent?.state.presentError("Invalid search pattern: \(error.localizedDescription)")
            return
        }

        // Use literal string matching instead of regex to avoid ReDoS
        let results = doc.searchAll(pattern, options: [.caseInsensitive])
        for result in results {
            markSelectionForRedaction(result)
        }
    }

    func removeRedactionMark(_ region: RedactionRegion) {
        guard let doc = pdfDocument,
              let page = doc.page(at: region.pageIndex) else { return }

        // Remove the visual mark annotation
        let markAnnotations = page.annotations.filter { ann in
            ann.type == "Square" && ann.contents == "Marked for Redaction" && ann.bounds == region.bounds
        }
        for ann in markAnnotations {
            page.removeAnnotation(ann)
        }

        redactionRegions.removeAll { $0.id == region.id }
    }

    func removeAllRedactionMarks() {
        guard let doc = pdfDocument else { return }

        for region in redactionRegions {
            guard let page = doc.page(at: region.pageIndex) else { continue }
            let markAnnotations = page.annotations.filter { ann in
                ann.type == "Square" && ann.contents == "Marked for Redaction"
            }
            for ann in markAnnotations {
                page.removeAnnotation(ann)
            }
        }
        redactionRegions.removeAll()
    }

    // MARK: - Apply Redactions

    func applyRedactions() async {
        guard let doc = pdfDocument,
              !redactionRegions.isEmpty else { return }

        await MainActor.run {
            isApplyingRedactions = true
            redactionProgress = 0
        }

        // Group regions by page
        let regionsByPage = Dictionary(grouping: redactionRegions) { $0.pageIndex }
        let totalRegions = redactionRegions.count
        var processedCount = 0

        // Rewrite the document with redactions applied
        let tempURL = FileCoordination.temporaryURL()

        do {
            try PDFRewriter.rewriteDocument(doc, to: tempURL) { page, pageIndex, context in
                guard let regions = regionsByPage[pageIndex] else { return }

                for region in regions {
                    // Draw a filled rectangle over the redacted area
                    context.drawRedaction(
                        over: region.bounds,
                        color: region.overlayColor,
                        overlayText: region.overlayText
                    )

                    processedCount += 1
                    let progress = Double(processedCount) / Double(totalRegions)
                    DispatchQueue.main.async { [weak self] in
                        self?.redactionProgress = progress
                    }
                }
            }

            // Load the redacted document
            guard let redactedDoc = PDFDocument(url: tempURL) else {
                throw OakReaderError.redactionFailed("Failed to load redacted document")
            }

            // Replace the current document's pages with redacted pages
            await MainActor.run {
                // Remove mark annotations from current pages
                for region in redactionRegions {
                    guard let page = doc.page(at: region.pageIndex) else { continue }
                    let markAnnotations = page.annotations.filter { ann in
                        ann.type == "Square" && ann.contents == "Marked for Redaction"
                    }
                    for ann in markAnnotations {
                        page.removeAnnotation(ann)
                    }
                }

                // Replace pages with redacted versions
                let pageCount = doc.pageCount
                for i in 0..<min(pageCount, redactedDoc.pageCount) {
                    guard let newPage = redactedDoc.page(at: i),
                          let copied = newPage.copy() as? PDFPage else { continue }
                    doc.removePage(at: i)
                    doc.insert(copied, at: i)
                }

                redactionRegions.removeAll()
                isApplyingRedactions = false
                redactionProgress = 1.0
                parent?.markDocumentEdited()
            }

            try? FileManager.default.removeItem(at: tempURL)

        } catch {
            await MainActor.run {
                isApplyingRedactions = false
                parent?.state.presentError("Redaction failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Computed Properties

    var hasRedactionMarks: Bool {
        !redactionRegions.isEmpty
    }

    var redactionCountLabel: String {
        let count = redactionRegions.count
        return count == 1 ? "1 redaction mark" : "\(count) redaction marks"
    }

    var isEncrypted: Bool {
        settings.isEncrypted
    }

    var securitySummary: String {
        var parts: [String] = []
        if settings.hasOpenPassword {
            parts.append("Open password set")
        }
        if settings.hasPermissionsPassword {
            parts.append("Permissions password set")
        }
        if !settings.allowPrinting {
            parts.append("Printing disabled")
        }
        if !settings.allowCopying {
            parts.append("Copying disabled")
        }
        if parts.isEmpty {
            return "No security applied"
        }
        return parts.joined(separator: ", ")
    }
}
