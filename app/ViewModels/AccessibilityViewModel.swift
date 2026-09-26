import Foundation
import PDFKit
import AppKit

@Observable
class AccessibilityViewModel {
    weak var parent: DocumentViewModel?

    var issues: [AccessibilityIssue] = []
    var isChecking: Bool = false

    init(parent: DocumentViewModel) {
        self.parent = parent
    }

    private var pdfDocument: PDFDocument? { parent?.pdfDocument }

    // MARK: - Run Accessibility Check

    func runCheck() async {
        guard let doc = pdfDocument else { return }

        await MainActor.run {
            isChecking = true
            issues = []
        }

        var detectedIssues: [AccessibilityIssue] = []

        // Check 1: Document has a title
        let title = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        if title == nil || title?.isEmpty == true {
            detectedIssues.append(AccessibilityIssue(
                severity: .error,
                message: "Document does not have a title set",
                suggestion: "Set a document title in Document Properties for screen reader accessibility"
            ))
        }

        // Check 2: Document language
        let language = doc.documentAttributes?["Language"] as? String
        if language == nil || language?.isEmpty == true {
            detectedIssues.append(AccessibilityIssue(
                severity: .warning,
                message: "Document language is not specified",
                suggestion: "Set the document language to help screen readers use correct pronunciation"
            ))
        }

        // Check 3: Check for tagged PDF structure
        // PDFKit doesn't expose tag structure directly, so we check for the presence of outline
        if doc.outlineRoot == nil || doc.outlineRoot?.numberOfChildren == 0 {
            detectedIssues.append(AccessibilityIssue(
                severity: .warning,
                message: "Document has no bookmarks/outline",
                suggestion: "Add bookmarks for document navigation, especially for longer documents"
            ))
        }

        // Check 4: Per-page checks
        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }

            // Check if page has text (scanned image)
            if !page.hasText {
                detectedIssues.append(AccessibilityIssue(
                    severity: .error,
                    message: "Page \(pageIndex + 1) has no text content (may be a scanned image)",
                    pageIndex: pageIndex,
                    suggestion: "This page may be a scanned image without selectable text"
                ))
            }

            // Check for images without alternative text
            let stampAnnotations = page.annotations.filter { $0.type == "Stamp" }
            for annotation in stampAnnotations {
                if annotation.contents == nil || annotation.contents?.isEmpty == true {
                    detectedIssues.append(AccessibilityIssue(
                        severity: .error,
                        message: "Image/stamp on page \(pageIndex + 1) has no alternative text",
                        pageIndex: pageIndex,
                        suggestion: "Add descriptive alternative text to the image annotation"
                    ))
                }
            }

            // Check for form fields without labels
            let widgetAnnotations = page.annotations.filter { $0.type == "Widget" }
            for widget in widgetAnnotations {
                if widget.fieldName == nil || widget.fieldName?.isEmpty == true {
                    detectedIssues.append(AccessibilityIssue(
                        severity: .error,
                        message: "Form field on page \(pageIndex + 1) has no name/label",
                        pageIndex: pageIndex,
                        suggestion: "Assign a descriptive name to the form field"
                    ))
                }
                // Check for tooltip (used as accessible description)
                let tooltip = widget.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/TU")) as? String
                if tooltip == nil || tooltip?.isEmpty == true {
                    detectedIssues.append(AccessibilityIssue(
                        severity: .warning,
                        message: "Form field '\(widget.fieldName ?? "unnamed")' on page \(pageIndex + 1) has no tooltip",
                        pageIndex: pageIndex,
                        suggestion: "Add a tooltip to provide accessible description for the form field"
                    ))
                }
            }

            // Check for link annotations without URL or destination
            let linkAnnotations = page.annotations.filter { $0.type == "Link" }
            for link in linkAnnotations {
                if link.url == nil && link.destination == nil {
                    detectedIssues.append(AccessibilityIssue(
                        severity: .warning,
                        message: "Link on page \(pageIndex + 1) has no URL or destination",
                        pageIndex: pageIndex,
                        suggestion: "Ensure all links have a valid target"
                    ))
                }
            }

            // Check contrast: very light text colors on annotations
            let freeTextAnnotations = page.annotations.filter { $0.type == "FreeText" }
            for annotation in freeTextAnnotations {
                if let fontColor = annotation.fontColor {
                    let brightness = fontColor.brightnessComponent
                    if brightness > 0.85 {
                        detectedIssues.append(AccessibilityIssue(
                            severity: .warning,
                            message: "Text annotation on page \(pageIndex + 1) may have low contrast",
                            pageIndex: pageIndex,
                            suggestion: "Use darker text colors for better readability"
                        ))
                    }
                }
            }
        }

        // Check 5: Document size / reading order
        if doc.pageCount > 50 && (doc.outlineRoot == nil || doc.outlineRoot?.numberOfChildren == 0) {
            detectedIssues.append(AccessibilityIssue(
                severity: .error,
                message: "Large document (\(doc.pageCount) pages) with no table of contents",
                suggestion: "Add bookmarks to enable navigation in large documents"
            ))
        }

        await MainActor.run {
            issues = detectedIssues
            isChecking = false
        }
    }
}
