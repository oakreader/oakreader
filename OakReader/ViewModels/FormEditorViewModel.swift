import Foundation
import PDFKit
import AppKit
import Vision

@Observable
class FormEditorViewModel {
    weak var parent: DocumentViewModel?

    var fields: [FormFieldModel] = []
    var selectedField: FormFieldModel?
    var currentFieldType: FormFieldType = .textField
    var isDetectingFields: Bool = false

    init(parent: DocumentViewModel) {
        self.parent = parent
    }

    private var pdfDocument: PDFDocument? { parent?.pdfDocument }

    // MARK: - Load Existing Fields

    func loadExistingFields() {
        guard let doc = pdfDocument else {
            fields = []
            return
        }

        var loadedFields: [FormFieldModel] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                var field = FormFieldModel(fieldType: widgetFieldType(for: annotation), bounds: annotation.bounds, pageIndex: i)
                field.name = annotation.fieldName ?? field.name
                if let font = annotation.font {
                    field.fontName = font.fontName
                    field.fontSize = font.pointSize
                }
                field.defaultValue = annotation.widgetStringValue ?? ""
                if let choices = annotation.choices {
                    field.options = choices
                }
                field.isReadOnly = annotation.isReadOnly
                loadedFields.append(field)
            }
        }
        fields = loadedFields
    }

    // MARK: - Add Field

    func addField(type: FormFieldType, at bounds: CGRect, on pageIndex: Int) {
        guard let doc = pdfDocument,
              let page = doc.page(at: pageIndex) else { return }

        var field = FormFieldModel(fieldType: type, bounds: bounds, pageIndex: pageIndex)
        field.fontSize = max(bounds.height * 0.6, 8)

        let annotation = field.createAnnotation()
        page.addAnnotation(annotation)

        fields.append(field)
        selectedField = field
        parent?.markDocumentEdited()
    }

    // MARK: - Update Field

    func updateField(_ updatedField: FormFieldModel) {
        guard let doc = pdfDocument,
              let page = doc.page(at: updatedField.pageIndex) else { return }

        // Find and remove the old annotation
        if let index = fields.firstIndex(where: { $0.id == updatedField.id }) {
            let oldField = fields[index]
            let oldAnnotation = page.annotations.first { ann in
                ann.type == "Widget" && ann.fieldName == oldField.name && ann.bounds == oldField.bounds
            }
            if let oldAnnotation {
                page.removeAnnotation(oldAnnotation)
            }

            // Create and add the updated annotation
            let newAnnotation = updatedField.createAnnotation()
            page.addAnnotation(newAnnotation)

            fields[index] = updatedField
            selectedField = updatedField
            parent?.markDocumentEdited()
        }
    }

    // MARK: - Delete Field

    func deleteField(_ field: FormFieldModel) {
        guard let doc = pdfDocument,
              let page = doc.page(at: field.pageIndex) else { return }

        // Find and remove the annotation from the page
        let annotation = page.annotations.first { ann in
            ann.type == "Widget" && ann.fieldName == field.name
        }
        if let annotation {
            page.removeAnnotation(annotation)
        }

        fields.removeAll { $0.id == field.id }
        if selectedField?.id == field.id {
            selectedField = nil
        }
        parent?.markDocumentEdited()
    }

    func deleteSelectedField() {
        guard let field = selectedField else { return }
        deleteField(field)
    }

    // MARK: - Auto-Detect Fields

    func autoDetectFields() async {
        guard let doc = pdfDocument else { return }

        await MainActor.run {
            isDetectingFields = true
        }

        var detectedFields: [FormFieldModel] = []

        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }

            // Render page to image for Vision analysis
            guard let cgImage = page.renderToCGImage(dpi: 150) else { continue }

            let pageRect = page.bounds(for: .mediaBox)

            do {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true

                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try handler.perform([request])

                guard let observations = request.results else { continue }

                // Analyze text observations to find likely form field locations
                // Look for patterns: labels followed by blank areas, underlines, or boxes
                var labelBounds: [(String, CGRect)] = []

                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let text = candidate.string

                    // Convert normalized Vision coordinates to PDF coordinates
                    let boundingBox = observation.boundingBox
                    let pdfBounds = CGRect(
                        x: boundingBox.origin.x * pageRect.width,
                        y: boundingBox.origin.y * pageRect.height,
                        width: boundingBox.width * pageRect.width,
                        height: boundingBox.height * pageRect.height
                    )

                    labelBounds.append((text, pdfBounds))
                }

                // Detect form field patterns
                for (text, bounds) in labelBounds {
                    let lowered = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

                    // Detect common form labels and create corresponding fields
                    if lowered.hasSuffix(":") || lowered.hasPrefix("name") || lowered.hasPrefix("email")
                        || lowered.hasPrefix("phone") || lowered.hasPrefix("address")
                        || lowered.hasPrefix("date") || lowered.hasPrefix("city")
                        || lowered.hasPrefix("state") || lowered.hasPrefix("zip")
                        || lowered.hasPrefix("company") || lowered.hasPrefix("title") {

                        // Place a text field to the right of the label
                        let fieldBounds = CGRect(
                            x: bounds.maxX + 10,
                            y: bounds.origin.y - 2,
                            width: max(200, pageRect.width - bounds.maxX - 50),
                            height: bounds.height + 4
                        )

                        // Only add if the field doesn't overlap existing fields
                        let overlaps = detectedFields.contains { existing in
                            existing.pageIndex == pageIndex && existing.bounds.intersects(fieldBounds)
                        }

                        if !overlaps && fieldBounds.maxX < pageRect.width - 20 {
                            var field = FormFieldModel(fieldType: .textField, bounds: fieldBounds, pageIndex: pageIndex)
                            field.name = text.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
                            field.tooltip = "Enter \(field.name)"
                            detectedFields.append(field)
                        }
                    }

                    // Detect checkbox patterns
                    if lowered.contains("yes") || lowered.contains("no")
                        || lowered.contains("agree") || lowered.contains("accept") {
                        let checkBounds = CGRect(
                            x: bounds.origin.x - 20,
                            y: bounds.origin.y,
                            width: 14,
                            height: 14
                        )

                        let overlaps = detectedFields.contains { existing in
                            existing.pageIndex == pageIndex && existing.bounds.intersects(checkBounds)
                        }

                        if !overlaps && checkBounds.origin.x >= 0 {
                            var field = FormFieldModel(fieldType: .checkbox, bounds: checkBounds, pageIndex: pageIndex)
                            field.name = text.trimmingCharacters(in: .whitespaces)
                            detectedFields.append(field)
                        }
                    }

                    // Detect signature lines
                    if lowered.contains("signature") || lowered.contains("sign here") {
                        let sigBounds = CGRect(
                            x: bounds.origin.x,
                            y: bounds.maxY + 5,
                            width: 200,
                            height: 40
                        )
                        let overlaps = detectedFields.contains { existing in
                            existing.pageIndex == pageIndex && existing.bounds.intersects(sigBounds)
                        }
                        if !overlaps {
                            var field = FormFieldModel(fieldType: .signature, bounds: sigBounds, pageIndex: pageIndex)
                            field.name = "Signature"
                            detectedFields.append(field)
                        }
                    }
                }

            } catch {
                // Continue to next page on error
                continue
            }
        }

        // Add detected fields to the document
        await MainActor.run {
            for field in detectedFields {
                guard let page = doc.page(at: field.pageIndex) else { continue }
                let annotation = field.createAnnotation()
                page.addAnnotation(annotation)
                fields.append(field)
            }
            isDetectingFields = false
            if !detectedFields.isEmpty {
                parent?.markDocumentEdited()
            }
        }
    }

    // MARK: - Tab Order

    func setTabOrder(_ orderedFieldIDs: [UUID]) {
        var reordered: [FormFieldModel] = []
        for id in orderedFieldIDs {
            if let field = fields.first(where: { $0.id == id }) {
                reordered.append(field)
            }
        }
        // Add any fields not in the order list
        for field in fields where !orderedFieldIDs.contains(field.id) {
            reordered.append(field)
        }
        fields = reordered
    }

    // MARK: - Helpers

    private func widgetFieldType(for annotation: PDFAnnotation) -> FormFieldType {
        switch annotation.widgetFieldType {
        case .text:
            return .textField
        case .button:
            if annotation.buttonWidgetStateString == "Yes" || annotation.buttonWidgetStateString == "Off" {
                return .checkbox
            }
            return .pushButton
        case .choice:
            return .dropdown
        case .signature:
            return .signature
        default:
            return .textField
        }
    }

    func fieldsOnPage(_ pageIndex: Int) -> [FormFieldModel] {
        fields.filter { $0.pageIndex == pageIndex }
    }
}
