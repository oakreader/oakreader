import Foundation
import PDFKit
import AppKit

struct AccessibilityService {

    func checkAccessibility(of document: PDFDocument) -> [AccessibilityIssue] {
        var issues: [AccessibilityIssue] = []

        // Check document-level properties
        issues.append(contentsOf: checkDocumentMetadata(document))

        // Check page-level properties
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            issues.append(contentsOf: checkPage(page, at: i))
        }

        // Check document structure
        issues.append(contentsOf: checkDocumentStructure(document))

        return issues
    }

    // MARK: - Document Metadata Checks

    private func checkDocumentMetadata(_ document: PDFDocument) -> [AccessibilityIssue] {
        var issues: [AccessibilityIssue] = []
        let attrs = document.documentAttributes ?? [:]

        // Check for document title
        let title = attrs[PDFDocumentAttribute.titleAttribute] as? String
        if title == nil || title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            issues.append(AccessibilityIssue(
                severity: .error,
                message: "Document is missing a title.",
                suggestion: "Add a descriptive title in Document Properties for screen readers."
            ))
        }

        // Check for language
        // PDFKit does not expose a language attribute directly; check the CGPDFDocument catalog
        let hasLanguage = checkForLanguageAttribute(document)
        if !hasLanguage {
            issues.append(AccessibilityIssue(
                severity: .error,
                message: "Document does not specify a language.",
                suggestion: "Set the document language to help screen readers pronounce text correctly."
            ))
        }

        // Check for author
        let author = attrs[PDFDocumentAttribute.authorAttribute] as? String
        if author == nil || author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            issues.append(AccessibilityIssue(
                severity: .info,
                message: "Document author is not set.",
                suggestion: "Add an author in Document Properties for better identification."
            ))
        }

        return issues
    }

    private func checkForLanguageAttribute(_ document: PDFDocument) -> Bool {
        guard let cgDoc = document.documentRef else { return false }
        guard let catalog = cgDoc.info else { return false }
        var cfLang: CGPDFStringRef?
        if CGPDFDictionaryGetString(catalog, "Lang", &cfLang), cfLang != nil {
            return true
        }
        // Also check the catalog directly
        guard let catalogDict = cgDoc.catalog else { return false }
        var langString: CGPDFStringRef?
        if CGPDFDictionaryGetString(catalogDict, "Lang", &langString), langString != nil {
            return true
        }
        return false
    }

    // MARK: - Page Checks

    private func checkPage(_ page: PDFPage, at index: Int) -> [AccessibilityIssue] {
        var issues: [AccessibilityIssue] = []

        // Check if page has extractable text
        let pageText = page.string ?? ""
        if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(AccessibilityIssue(
                severity: .error,
                message: "Page \(index + 1) has no extractable text.",
                pageIndex: index,
                suggestion: "Run OCR on this page to make its content accessible to screen readers."
            ))
        }

        // Check for images without alt text (stamp annotations or image-based content)
        for annotation in page.annotations {
            if annotation.type == "Stamp" || annotation.type == "FileAttachment" {
                let hasAltText = annotation.contents != nil &&
                    !(annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !hasAltText {
                    issues.append(AccessibilityIssue(
                        severity: .warning,
                        message: "Page \(index + 1) has an image annotation without alternative text.",
                        pageIndex: index,
                        suggestion: "Add a description to the annotation's contents for screen readers."
                    ))
                }
            }

            // Check link annotations for missing descriptions
            if annotation.type == "Link" {
                let hasDescription = annotation.contents != nil &&
                    !(annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !hasDescription {
                    issues.append(AccessibilityIssue(
                        severity: .warning,
                        message: "Page \(index + 1) has a link without a description.",
                        pageIndex: index,
                        suggestion: "Add descriptive text to the link annotation for accessibility."
                    ))
                }
            }
        }

        return issues
    }

    // MARK: - Structure Checks

    private func checkDocumentStructure(_ document: PDFDocument) -> [AccessibilityIssue] {
        var issues: [AccessibilityIssue] = []

        // Check for document structure tags (Tagged PDF)
        let isTagged = checkForStructureTags(document)
        if !isTagged {
            issues.append(AccessibilityIssue(
                severity: .error,
                message: "Document does not contain structure tags (not a Tagged PDF).",
                suggestion: "Tagged PDFs provide proper reading order and structure for assistive technologies."
            ))
        }

        // Check for bookmarks / table of contents
        if document.outlineRoot == nil || document.outlineRoot?.numberOfChildren == 0 {
            if document.pageCount > 3 {
                issues.append(AccessibilityIssue(
                    severity: .warning,
                    message: "Multi-page document has no bookmarks or table of contents.",
                    suggestion: "Add bookmarks to improve navigation for all users."
                ))
            }
        }

        // Check that all pages are a reasonable size (not scanned at odd sizes)
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            let size = page.bounds(for: .mediaBox).size
            if size.width < 72 || size.height < 72 {
                issues.append(AccessibilityIssue(
                    severity: .warning,
                    message: "Page \(i + 1) has an unusually small size (\(Int(size.width))x\(Int(size.height)) pt).",
                    pageIndex: i,
                    suggestion: "Check if this page was created correctly."
                ))
            }
        }

        return issues
    }

    private func checkForStructureTags(_ document: PDFDocument) -> Bool {
        guard let cgDoc = document.documentRef else { return false }
        guard let catalog = cgDoc.catalog else { return false }

        // Check for MarkInfo dictionary with Marked = true
        var markInfoDict: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "MarkInfo", &markInfoDict),
           let markInfo = markInfoDict {
            var isMarked: CGPDFBoolean = 0
            if CGPDFDictionaryGetBoolean(markInfo, "Marked", &isMarked) {
                return isMarked != 0
            }
        }

        // Check for StructTreeRoot
        var structTreeRoot: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "StructTreeRoot", &structTreeRoot) {
            return structTreeRoot != nil
        }

        return false
    }
}
