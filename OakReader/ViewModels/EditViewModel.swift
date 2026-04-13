import Foundation
import PDFKit
import AppKit

@Observable
class EditViewModel {
    weak var parent: DocumentViewModel?

    // MARK: - Text Editing State

    var isEditingText: Bool = false
    var editingText: String = ""
    var editingBounds: CGRect = .zero
    var editingPageIndex: Int = 0
    var editingFontName: String = PDFDefaults.defaultFontName
    var editingFontSize: CGFloat = PDFDefaults.defaultFontSize
    var editingFontColor: NSColor = .black

    // MARK: - Image Editing State

    var selectedImageBounds: CGRect?
    var selectedImagePageIndex: Int?

    // MARK: - Undo Support

    private var originalAnnotationForEdit: PDFAnnotation?

    init(parent: DocumentViewModel) {
        self.parent = parent
    }

    private var pdfDocument: PDFDocument? { parent?.pdfDocument }

    // MARK: - Text Editing (Redact-and-Overlay Approach)

    /// Begin editing text at a given location on a page.
    /// This captures the existing text region so we can later replace it.
    func beginTextEdit(at bounds: CGRect, on pageIndex: Int) {
        guard let doc = pdfDocument,
              let page = doc.page(at: pageIndex) else { return }

        editingPageIndex = pageIndex
        editingBounds = bounds
        isEditingText = true

        // Try to extract existing text in the bounds area
        if let selection = page.selection(for: bounds) {
            editingText = selection.string ?? ""
        } else {
            editingText = ""
        }

        // Detect font from any existing freeText annotation at this location
        let existingAnnotation = page.annotations.first { ann in
            ann.type == "FreeText" && ann.bounds.intersects(bounds)
        }
        if let existing = existingAnnotation {
            originalAnnotationForEdit = existing
            editingText = existing.contents ?? ""
            if let font = existing.font {
                editingFontName = font.fontName
                editingFontSize = font.pointSize
            }
            if let fontColor = existing.fontColor {
                editingFontColor = fontColor
            }
        } else {
            originalAnnotationForEdit = nil
        }
    }

    /// Commit the current text edit by applying a white-out rectangle
    /// and placing a new freeText annotation with the edited text.
    func commitTextEdit() {
        guard isEditingText,
              let doc = pdfDocument,
              let page = doc.page(at: editingPageIndex) else {
            cancelTextEdit()
            return
        }

        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // If user cleared all text, remove existing annotation if any
            if let original = originalAnnotationForEdit {
                page.removeAnnotation(original)
            }
            cancelTextEdit()
            parent?.markDocumentEdited()
            return
        }

        // Remove the original annotation if we were editing one
        if let original = originalAnnotationForEdit {
            page.removeAnnotation(original)
        }

        // Create a white-out rectangle to cover original content
        let whiteOut = PDFAnnotation(bounds: editingBounds, forType: .square, withProperties: nil)
        whiteOut.color = .white
        whiteOut.interiorColor = .white
        let noBorder = PDFBorder()
        noBorder.lineWidth = 0
        whiteOut.border = noBorder
        page.addAnnotation(whiteOut)

        // Place the new freeText annotation with the edited text
        let font = NSFont(name: editingFontName, size: editingFontSize)
            ?? NSFont.systemFont(ofSize: editingFontSize)
        let textAnnotation = PDFAnnotation.freeText(
            bounds: editingBounds,
            text: trimmed,
            font: font,
            color: editingFontColor
        )
        page.addAnnotation(textAnnotation)

        parent?.markDocumentEdited()
        resetEditState()
    }

    /// Cancel the current text edit without committing changes.
    func cancelTextEdit() {
        resetEditState()
    }

    /// Add new text at a given point on a page.
    func addText(_ text: String, at point: CGPoint, on pageIndex: Int) {
        guard let doc = pdfDocument,
              let page = doc.page(at: pageIndex) else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let font = NSFont(name: editingFontName, size: editingFontSize)
            ?? NSFont.systemFont(ofSize: editingFontSize)

        // Calculate bounds based on text size
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (trimmed as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 4
        let bounds = CGRect(
            x: point.x,
            y: point.y - textSize.height - padding,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )

        let annotation = PDFAnnotation.freeText(
            bounds: bounds,
            text: trimmed,
            font: font,
            color: editingFontColor
        )
        page.addAnnotation(annotation)
        parent?.markDocumentEdited()
    }

    /// Add an image at a given point on a page.
    func addImage(_ image: NSImage, at point: CGPoint, on pageIndex: Int) {
        guard let doc = pdfDocument,
              let page = doc.page(at: pageIndex) else { return }

        let pageRect = page.bounds(for: .mediaBox)

        // Scale image to fit reasonably on the page
        let maxDimension = min(pageRect.width, pageRect.height) * 0.5
        let scaledImage = image.resizedToFit(maxDimension: maxDimension)
        let imgSize = scaledImage.size

        let bounds = CGRect(
            x: min(point.x, pageRect.width - imgSize.width),
            y: min(max(point.y - imgSize.height, 0), pageRect.height - imgSize.height),
            width: imgSize.width,
            height: imgSize.height
        )

        // Create a stamp annotation with the image
        let annotation = PDFAnnotation(bounds: bounds, forType: .stamp, withProperties: nil)

        // Render the image into the stamp annotation's appearance stream
        if let imageData = scaledImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: imageData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            let appearanceImage = NSImage(data: pngData) ?? scaledImage
            let appearance = NSImage(size: bounds.size)
            appearance.lockFocus()
            appearanceImage.draw(in: CGRect(origin: .zero, size: bounds.size))
            appearance.unlockFocus()
            // PDFKit stamp annotations display their appearance via the name or image property
            annotation.setValue(appearance, forAnnotationKey: PDFAnnotationKey(rawValue: "/AP"))
        }

        page.addAnnotation(annotation)
        parent?.markDocumentEdited()
    }

    /// Replace an existing image annotation with a new image.
    func replaceImage(with newImage: NSImage) {
        guard let bounds = selectedImageBounds,
              let pageIndex = selectedImagePageIndex,
              let doc = pdfDocument,
              let page = doc.page(at: pageIndex) else { return }

        // Find and remove the existing image annotation at the selected bounds
        let existing = page.annotations.first { $0.bounds == bounds }
        if let existing {
            page.removeAnnotation(existing)
        }

        // Add the new image at the same location
        addImage(newImage, at: CGPoint(x: bounds.origin.x, y: bounds.maxY), on: pageIndex)

        selectedImageBounds = nil
        selectedImagePageIndex = nil
    }

    // MARK: - Font Settings

    func setFont(name: String) {
        editingFontName = name
    }

    func setFontSize(_ size: CGFloat) {
        editingFontSize = max(1, min(size, 200))
    }

    func setFontColor(_ color: NSColor) {
        editingFontColor = color
    }

    // MARK: - Private

    private func resetEditState() {
        isEditingText = false
        editingText = ""
        editingBounds = .zero
        editingPageIndex = 0
        originalAnnotationForEdit = nil
    }
}
