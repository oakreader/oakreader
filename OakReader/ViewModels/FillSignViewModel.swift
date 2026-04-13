import Foundation
import PDFKit
import AppKit

@Observable
class FillSignViewModel {
    weak var parent: DocumentViewModel?

    var savedSignatures: [SignatureModel] = []
    var activeSignature: SignatureModel?
    var isPlacingSignature: Bool = false

    // MARK: - Storage Key

    private static let signaturesKey = "OakReader_SavedSignatures"

    init(parent: DocumentViewModel) {
        self.parent = parent
        loadSavedSignatures()
    }

    private var pdfDocument: PDFDocument? { parent?.pdfDocument }

    // MARK: - Fill Form Fields

    func fillField(_ field: FormFieldModel, with value: String) {
        guard let doc = pdfDocument,
              let page = doc.page(at: field.pageIndex) else { return }

        // Find the widget annotation matching this field
        let widget = page.annotations.first { ann in
            ann.type == "Widget" && ann.fieldName == field.name
        }

        guard let widget else { return }

        switch field.fieldType {
        case .textField:
            widget.widgetStringValue = value
        case .checkbox:
            widget.buttonWidgetState = (value == "true" || value == "Yes") ? .onState : .offState
        case .radioButton:
            widget.buttonWidgetState = (value == "true" || value == "Yes") ? .onState : .offState
        case .dropdown:
            widget.widgetStringValue = value
        case .pushButton:
            widget.caption = value
        case .signature:
            // Signature fields are filled via placeSignature
            break
        }

        parent?.markDocumentEdited()
    }

    func fillFieldByName(_ fieldName: String, with value: String) {
        guard let doc = pdfDocument else { return }

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                if annotation.fieldName == fieldName {
                    annotation.widgetStringValue = value
                    parent?.markDocumentEdited()
                    return
                }
            }
        }
    }

    // MARK: - Create Signatures

    func createSignature(from points: [[CGPoint]], name: String = "Signature") {
        let signature = SignatureModel(drawn: points, name: name)
        savedSignatures.append(signature)
        activeSignature = signature
        persistSignatures()
    }

    func createSignature(fromText text: String, fontName: String = "Snell Roundhand", name: String = "Signature") {
        let signature = SignatureModel(typed: text, fontName: fontName, name: name)
        savedSignatures.append(signature)
        activeSignature = signature
        persistSignatures()
    }

    func createSignature(from image: NSImage, name: String = "Signature") {
        let signature = SignatureModel(image: image, name: name)
        savedSignatures.append(signature)
        activeSignature = signature
        persistSignatures()
    }

    // MARK: - Place Signature

    func placeSignature(_ signature: SignatureModel, at point: CGPoint, on pageIndex: Int) {
        guard let doc = pdfDocument,
              let page = doc.page(at: pageIndex) else { return }

        let signatureImage = signature.renderToImage(size: CGSize(width: 200, height: 60))

        let bounds = CGRect(
            x: point.x - 100,
            y: point.y - 30,
            width: 200,
            height: 60
        )

        // Clamp bounds to page
        let pageRect = page.bounds(for: .mediaBox)
        let clampedBounds = CGRect(
            x: max(0, min(bounds.origin.x, pageRect.width - bounds.width)),
            y: max(0, min(bounds.origin.y, pageRect.height - bounds.height)),
            width: bounds.width,
            height: bounds.height
        )

        // Create a stamp annotation for the signature
        let annotation = PDFAnnotation(bounds: clampedBounds, forType: .stamp, withProperties: nil)
        annotation.stampName = "Signature"

        // Create an appearance stream for the signature image
        let appearance = createAppearanceImage(from: signatureImage, size: clampedBounds.size)
        if let tiffData = appearance.tiffRepresentation {
            annotation.setValue(NSImage(data: tiffData), forAnnotationKey: PDFAnnotationKey(rawValue: "/AP"))
        }

        page.addAnnotation(annotation)
        isPlacingSignature = false
        parent?.markDocumentEdited()
    }

    func placeSignatureInField(_ signature: SignatureModel, field: FormFieldModel) {
        guard let doc = pdfDocument,
              let page = doc.page(at: field.pageIndex) else { return }

        let signatureImage = signature.renderToImage(size: field.bounds.size)

        // Find and remove the existing widget annotation
        let widget = page.annotations.first { ann in
            ann.type == "Widget" && ann.fieldName == field.name
        }

        if let widget {
            page.removeAnnotation(widget)
        }

        // Place the signature as a stamp annotation at the field location
        let annotation = PDFAnnotation(bounds: field.bounds, forType: .stamp, withProperties: nil)
        annotation.stampName = "Signature"

        let appearance = createAppearanceImage(from: signatureImage, size: field.bounds.size)
        if let tiffData = appearance.tiffRepresentation {
            annotation.setValue(NSImage(data: tiffData), forAnnotationKey: PDFAnnotationKey(rawValue: "/AP"))
        }

        page.addAnnotation(annotation)
        isPlacingSignature = false
        parent?.markDocumentEdited()
    }

    // MARK: - Manage Signatures

    func deleteSignature(_ signature: SignatureModel) {
        savedSignatures.removeAll { $0.id == signature.id }
        if activeSignature?.id == signature.id {
            activeSignature = nil
        }
        persistSignatures()
    }

    func selectSignature(_ signature: SignatureModel) {
        activeSignature = signature
        isPlacingSignature = true
    }

    // MARK: - Persistence

    func loadSavedSignatures() {
        guard let data = UserDefaults.standard.data(forKey: Self.signaturesKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([SavedSignatureData].self, from: data)
            savedSignatures = decoded.map { saved in
                switch saved.type {
                case .drawn:
                    return SignatureModel(drawn: saved.points ?? [[]], name: saved.name)
                case .typed:
                    return SignatureModel(typed: saved.text ?? "", fontName: saved.fontName ?? "Snell Roundhand", name: saved.name)
                case .image:
                    if let imageData = saved.imageData, let img = NSImage(data: imageData) {
                        return SignatureModel(image: img, name: saved.name)
                    }
                    return SignatureModel(drawn: [[]], name: saved.name)
                }
            }
        } catch {
            savedSignatures = []
        }
    }

    func saveSignature(_ signature: SignatureModel) {
        if !savedSignatures.contains(where: { $0.id == signature.id }) {
            savedSignatures.append(signature)
        }
        persistSignatures()
    }

    private func persistSignatures() {
        let dataModels: [SavedSignatureData] = savedSignatures.map { sig in
            switch sig.type {
            case .drawn(let points):
                return SavedSignatureData(type: .drawn, name: sig.name, points: points, text: nil, fontName: nil, imageData: nil)
            case .typed(let text, let fontName):
                return SavedSignatureData(type: .typed, name: sig.name, points: nil, text: text, fontName: fontName, imageData: nil)
            case .image:
                return SavedSignatureData(type: .image, name: sig.name, points: nil, text: nil, fontName: nil, imageData: sig.imageData)
            }
        }
        if let data = try? JSONEncoder().encode(dataModels) {
            UserDefaults.standard.set(data, forKey: Self.signaturesKey)
        }
    }

    // MARK: - Helpers

    private func createAppearanceImage(from source: NSImage, size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        source.draw(in: NSRect(origin: .zero, size: size),
                     from: NSRect(origin: .zero, size: source.size),
                     operation: .sourceOver,
                     fraction: 1.0)
        image.unlockFocus()
        return image
    }
}

// MARK: - Codable Signature Storage

private enum SavedSignatureType: String, Codable {
    case drawn, typed, image
}

private struct SavedSignatureData: Codable {
    let type: SavedSignatureType
    let name: String
    let points: [[CGPoint]]?
    let text: String?
    let fontName: String?
    let imageData: Data?
}

extension CGPoint: @retroactive Codable {
    enum CodingKeys: String, CodingKey {
        case x, y
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let x = try container.decode(CGFloat.self, forKey: .x)
        let y = try container.decode(CGFloat.self, forKey: .y)
        self.init(x: x, y: y)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
    }
}
