import Foundation
import PDFKit
import AppKit

@Observable
class AccessibilityViewModel {
    weak var parent: DocumentViewModel?

    var tagTree: [AccessibilityTagNode] = []
    var issues: [AccessibilityIssue] = []
    var isChecking: Bool = false
    var selectedNode: AccessibilityTagNode?

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

            // Check if page has text (scanned image without OCR)
            if !page.hasText {
                detectedIssues.append(AccessibilityIssue(
                    severity: .error,
                    message: "Page \(pageIndex + 1) has no text content (may be a scanned image)",
                    pageIndex: pageIndex,
                    suggestion: "Run OCR on this page to make text accessible to screen readers"
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

    // MARK: - Load Tag Structure

    func loadTags() {
        guard let doc = pdfDocument else {
            tagTree = []
            return
        }

        // Build a tag tree from the document structure
        // Since PDFKit doesn't expose the full structure tree, we build a
        // representation from the outline and page annotations
        var tree: [AccessibilityTagNode] = []

        // Create a Document root node
        var rootNode = AccessibilityTagNode(tagType: .document)

        // Add sections from the outline
        if let outlineRoot = doc.outlineRoot {
            for i in 0..<outlineRoot.numberOfChildren {
                guard let child = outlineRoot.child(at: i) else { continue }
                let sectionNode = buildTagNodeFromOutline(child, in: doc, level: 1)
                rootNode.children.append(sectionNode)
            }
        }

        // If no outline exists, create a flat structure from pages
        if rootNode.children.isEmpty {
            for pageIndex in 0..<doc.pageCount {
                guard let page = doc.page(at: pageIndex) else { continue }
                var pageNode = AccessibilityTagNode(tagType: .section, pageIndex: pageIndex)
                pageNode.actualText = "Page \(pageIndex + 1)"

                // Add paragraph nodes for text content
                if let text = page.string, !text.isEmpty {
                    let paragraphs = text.components(separatedBy: "\n\n")
                    for para in paragraphs where !para.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        var paraNode = AccessibilityTagNode(tagType: .paragraph, pageIndex: pageIndex)
                        paraNode.actualText = String(para.prefix(100))
                        pageNode.children.append(paraNode)
                    }
                }

                // Add figure nodes for image annotations
                let stamps = page.annotations.filter { $0.type == "Stamp" }
                for stamp in stamps {
                    var figNode = AccessibilityTagNode(tagType: .figure, pageIndex: pageIndex, bounds: stamp.bounds)
                    figNode.alternativeText = stamp.contents
                    pageNode.children.append(figNode)
                }

                // Add form nodes for widget annotations
                let widgets = page.annotations.filter { $0.type == "Widget" }
                for widget in widgets {
                    var formNode = AccessibilityTagNode(tagType: .form, pageIndex: pageIndex, bounds: widget.bounds)
                    formNode.actualText = widget.fieldName
                    pageNode.children.append(formNode)
                }

                rootNode.children.append(pageNode)
            }
        }

        tree.append(rootNode)
        tagTree = tree
    }

    // MARK: - Update Tag

    func updateTag(_ updatedNode: AccessibilityTagNode) {
        // Update the tag node in the tree
        func updateInChildren(_ nodes: inout [AccessibilityTagNode]) -> Bool {
            for i in 0..<nodes.count {
                if nodes[i].id == updatedNode.id {
                    nodes[i] = updatedNode
                    return true
                }
                if updateInChildren(&nodes[i].children) {
                    return true
                }
            }
            return false
        }

        _ = updateInChildren(&tagTree)

        // If the updated node is a figure with alternative text, update the annotation
        if updatedNode.tagType == .figure,
           let pageIndex = updatedNode.pageIndex,
           let bounds = updatedNode.bounds,
           let doc = pdfDocument,
           let page = doc.page(at: pageIndex) {

            let annotation = page.annotations.first { $0.bounds == bounds }
            if let annotation {
                annotation.contents = updatedNode.alternativeText
                parent?.markDocumentEdited()
            }
        }

        // If the updated node is a form field, update the field name
        if updatedNode.tagType == .form,
           let pageIndex = updatedNode.pageIndex,
           let bounds = updatedNode.bounds,
           let doc = pdfDocument,
           let page = doc.page(at: pageIndex) {

            let annotation = page.annotations.first { $0.type == "Widget" && $0.bounds == bounds }
            if let annotation {
                annotation.fieldName = updatedNode.actualText
                parent?.markDocumentEdited()
            }
        }
    }

    // MARK: - Fix Issues

    func fixIssue(_ issue: AccessibilityIssue) {
        guard let doc = pdfDocument else { return }

        switch issue.message {
        case let msg where msg.contains("no title"):
            // Set a default title from filename
            var attrs = doc.documentAttributes ?? [:]
            attrs[PDFDocumentAttribute.titleAttribute] = parent?.fileName ?? "Untitled"
            doc.documentAttributes = attrs
            parent?.markDocumentEdited()

        case let msg where msg.contains("no text content"):
            // Suggest OCR - navigate to the page
            if let pageIndex = issue.pageIndex {
                parent?.viewer.goToPage(pageIndex)
            }

        default:
            // Navigate to the relevant page if available
            if let pageIndex = issue.pageIndex {
                parent?.viewer.goToPage(pageIndex)
            }
        }
    }

    // MARK: - Computed Properties

    var errorCount: Int {
        issues.filter { $0.severity == .error }.count
    }

    var warningCount: Int {
        issues.filter { $0.severity == .warning }.count
    }

    var infoCount: Int {
        issues.filter { $0.severity == .info }.count
    }

    var isAccessible: Bool {
        errorCount == 0
    }

    var accessibilitySummary: String {
        guard !issues.isEmpty else {
            return isChecking ? "Checking..." : "No issues found"
        }
        var parts: [String] = []
        if errorCount > 0 { parts.append("\(errorCount) error\(errorCount == 1 ? "" : "s")") }
        if warningCount > 0 { parts.append("\(warningCount) warning\(warningCount == 1 ? "" : "s")") }
        if infoCount > 0 { parts.append("\(infoCount) info") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Helpers

    private func buildTagNodeFromOutline(_ outline: PDFOutline, in document: PDFDocument, level: Int) -> AccessibilityTagNode {
        let headingType: PDFTagType
        switch level {
        case 1: headingType = .heading1
        case 2: headingType = .heading2
        case 3: headingType = .heading3
        case 4: headingType = .heading4
        case 5: headingType = .heading5
        default: headingType = .heading6
        }

        var pageIndex: Int?
        if let destination = outline.destination, let page = destination.page {
            pageIndex = document.index(for: page)
        }

        var node = AccessibilityTagNode(tagType: headingType, pageIndex: pageIndex)
        node.actualText = outline.label

        for i in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: i) else { continue }
            let childNode = buildTagNodeFromOutline(child, in: document, level: level + 1)
            node.children.append(childNode)
        }

        return node
    }
}
