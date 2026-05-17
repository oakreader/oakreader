import Foundation
import PDFKit
import AppKit

@Observable
class AnnotationViewModel {
    weak var parent: DocumentViewModel?

    // MARK: - Current Tool State

    var currentTool: AnnotationTool = .none
    var strokeColor: NSColor = PDFDefaults.annotationDefaultColor
    var fillColor: NSColor? = nil
    var lineWidth: CGFloat = PDFDefaults.annotationDefaultLineWidth
    var opacity: CGFloat = 1.0
    // MARK: - Annotations List

    var annotationModels: [AnnotationModel] = []

    // MARK: - DB Persistence

    /// Maps PDFAnnotation object identity to its persistent DB ID.
    private var annotationIdMap: [ObjectIdentifier: String] = [:]

    init(parent: DocumentViewModel) {
        self.parent = parent
    }

    private var pdfDocument: PDFDocument? { parent?.pdfDocument }

    private var annotationStore: AnnotationStore? {
        guard let db = parent?.database else { return nil }
        return AnnotationStore(database: db)
    }

    private var attachmentId: String? { parent?.attachmentId }
    private var itemId: String? { parent?.itemId }

    // MARK: - ID Mapping

    private func persistentId(for annotation: PDFAnnotation) -> String? {
        annotationIdMap[ObjectIdentifier(annotation)]
    }

    private func registerMapping(_ annotation: PDFAnnotation, id: String) {
        annotationIdMap[ObjectIdentifier(annotation)] = id
    }

    private func removeMapping(_ annotation: PDFAnnotation) {
        annotationIdMap.removeValue(forKey: ObjectIdentifier(annotation))
    }

    // MARK: - Tool Selection

    func selectTool(_ tool: AnnotationTool) {
        currentTool = tool
    }

    func deselectTool() {
        currentTool = .none
    }

    // MARK: - Quiz Highlight

    /// Creates a purple highlight tagged as a quiz source and returns the annotation DB ID.
    @discardableResult
    func addQuizHighlight(for selection: PDFSelection) -> String? {
        guard let doc = pdfDocument else { return nil }
        let quizColor = NSColor(red: 0.64, green: 0.54, blue: 0.90, alpha: 0.5)
        var resultId: String?

        for page in selection.pages {
            let selBounds = selection.bounds(for: page)
            guard selBounds.width > 0, selBounds.height > 0 else { continue }

            let annotation = PDFAnnotation(bounds: selBounds, forType: .highlight, withProperties: nil)
            annotation.color = quizColor
            annotation.contents = "[quiz-source]"

            // Set quadrilateral points for precise text coverage
            let lineSelections = selection.selectionsByLine()
            var quadPoints: [NSValue] = []
            for lineSel in lineSelections {
                let lb = lineSel.bounds(for: page)
                guard lb.width > 0, lb.height > 0 else { continue }
                quadPoints.append(NSValue(point: NSPoint(x: lb.minX, y: lb.minY)))
                quadPoints.append(NSValue(point: NSPoint(x: lb.maxX, y: lb.minY)))
                quadPoints.append(NSValue(point: NSPoint(x: lb.minX, y: lb.maxY)))
                quadPoints.append(NSValue(point: NSPoint(x: lb.maxX, y: lb.maxY)))
            }
            if !quadPoints.isEmpty {
                annotation.setValue(quadPoints, forAnnotationKey: .quadPoints)
            }

            page.addAnnotation(annotation)
            let pageIndex = doc.index(for: page)

            // Persist to DB and capture the ID
            let id = UUID().uuidString
            persistQuizHighlight(
                pdfAnnotation: annotation,
                pageIndex: pageIndex,
                selectedText: selection.string,
                id: id
            )
            if resultId == nil {
                resultId = id
            }
        }
        parent?.markDocumentEdited()
        refreshAnnotationModels()
        return resultId
    }

    /// Persist a quiz highlight annotation to the store with a known ID.
    private func persistQuizHighlight(
        pdfAnnotation: PDFAnnotation,
        pageIndex: Int,
        selectedText: String?,
        id: String
    ) {
        guard let store = annotationStore,
              let attId = attachmentId,
              let itmId = itemId else { return }

        let now = Date().iso8601String

        var quadPts: [[CGFloat]]? = nil
        if let qp = pdfAnnotation.value(forAnnotationKey: .quadPoints) as? [NSValue] {
            quadPts = qp.map { val in
                let pt = val.pointValue
                return [pt.x, pt.y]
            }
        }
        let position = PDFAnnotationPosition(
            pageIndex: pageIndex,
            bounds: pdfAnnotation.bounds,
            quadPoints: quadPts
        )
        guard let positionJson = position.toJSON() else { return }

        let style = AnnotationStyle(
            lineWidth: pdfAnnotation.border?.lineWidth,
            opacity: pdfAnnotation.color.alphaComponent,
            fontName: nil,
            fontSize: nil,
            interiorColorHex: nil
        )
        let styleJson = style.toJSON()

        let pageHeight = pdfAnnotation.page?.bounds(for: .mediaBox).height ?? 792
        let sortIndex = AnnotationStore.makeSortIndex(
            pageIndex: pageIndex,
            bounds: pdfAnnotation.bounds,
            pageHeight: pageHeight
        )

        let record = AnnotationRecord(
            id: id,
            userId: localUserId,
            itemId: itmId,
            attachmentId: attId,
            key: AnnotationStore.generateKey(),
            type: "highlight",
            authorName: nil,
            text: selectedText,
            comment: "[quiz-source]",
            color: pdfAnnotation.color.hexString,
            pageLabel: "\(pageIndex + 1)",
            sortIndex: sortIndex,
            positionKind: "pdf",
            positionJson: positionJson,
            styleJson: styleJson,
            source: "oakreader",
            sourceKey: nil,
            isExternal: false,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )

        store.upsert(record)
        registerMapping(pdfAnnotation, id: id)
    }

    // MARK: - Highlight / Underline / Strikethrough

    func addHighlight(for selection: PDFSelection) {
        guard let doc = pdfDocument else { return }
        let effectiveColor = strokeColor.withAlphaComponent(opacity * 0.5)
        for page in selection.pages {
            let selBounds = selection.bounds(for: page)

            // Create one highlight annotation covering the full selection on this page
            guard selBounds.width > 0, selBounds.height > 0 else { continue }
            let annotation = PDFAnnotation(bounds: selBounds, forType: .highlight, withProperties: nil)
            annotation.color = effectiveColor

            // Set quadrilateral points per line for precise text coverage
            let lineSelections = selection.selectionsByLine()
            var quadPoints: [NSValue] = []
            for lineSel in lineSelections {
                let lb = lineSel.bounds(for: page)
                guard lb.width > 0, lb.height > 0 else { continue }
                // Quad points: bottom-left, bottom-right, top-left, top-right (PDFKit order)
                quadPoints.append(NSValue(point: NSPoint(x: lb.minX, y: lb.minY)))
                quadPoints.append(NSValue(point: NSPoint(x: lb.maxX, y: lb.minY)))
                quadPoints.append(NSValue(point: NSPoint(x: lb.minX, y: lb.maxY)))
                quadPoints.append(NSValue(point: NSPoint(x: lb.maxX, y: lb.maxY)))
            }
            if !quadPoints.isEmpty {
                annotation.setValue(quadPoints, forAnnotationKey: .quadPoints)
            }

            page.addAnnotation(annotation)
            let pageIndex = doc.index(for: page)

            // Persist to DB
            let selectedText = selection.string
            persistToStore(
                pdfAnnotation: annotation,
                pageIndex: pageIndex,
                selectedText: selectedText,
                existingId: nil
            )
        }
        parent?.markDocumentEdited()
        refreshAnnotationModels()
    }

    func addUnderline(for selection: PDFSelection) {
        guard let doc = pdfDocument else { return }
        let effectiveColor = strokeColor.withAlphaComponent(opacity)
        for page in selection.pages {
            let bounds = selection.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            let annotation = PDFAnnotation.underline(bounds: bounds, color: effectiveColor)
            page.addAnnotation(annotation)
            let pageIndex = doc.index(for: page)

            // Persist to DB
            let selectedText = selection.string
            persistToStore(
                pdfAnnotation: annotation,
                pageIndex: pageIndex,
                selectedText: selectedText,
                existingId: nil
            )
        }
        parent?.markDocumentEdited()
        refreshAnnotationModels()
    }

    // MARK: - Delete / Update

    func deleteAnnotation(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        page.removeAnnotation(annotation)
        // Soft-delete from DB
        if let dbId = persistentId(for: annotation) {
            annotationStore?.softDelete(id: dbId)
            removeMapping(annotation)
        }
        parent?.state.selectedAnnotation = nil
        parent?.markDocumentEdited()
        refreshAnnotationModels()
    }

    func updateAnnotation(_ annotation: PDFAnnotation, properties: AnnotationModel) {
        properties.apply(to: annotation)
        // Persist update to DB
        if let page = annotation.page, let doc = pdfDocument {
            let pageIndex = doc.index(for: page)
            persistToStore(
                pdfAnnotation: annotation,
                pageIndex: pageIndex,
                selectedText: nil,
                existingId: persistentId(for: annotation)
            )
        }
        parent?.markDocumentEdited()
        refreshAnnotationModels()
    }

    func selectAnnotation(_ annotation: PDFAnnotation?) {
        parent?.state.selectedAnnotation = annotation
    }

    // MARK: - Centralized Mutation Methods (for bypass path fix)

    func updateAnnotationColor(_ annotation: PDFAnnotation, color: NSColor) {
        let alpha = annotation.color.alphaComponent
        annotation.color = color.withAlphaComponent(alpha)
        persistUpdate(for: annotation)
        parent?.markDocumentEdited()
        refreshAnnotationModels()
    }

    func updateAnnotationLineWidth(_ annotation: PDFAnnotation, lineWidth: CGFloat) {
        let border = PDFBorder()
        border.lineWidth = lineWidth
        annotation.border = border
        persistUpdate(for: annotation)
        parent?.markDocumentEdited()
        refreshAnnotationModels()
    }

    func updateAnnotationOpacity(_ annotation: PDFAnnotation, opacity: CGFloat) {
        annotation.color = annotation.color.withAlphaComponent(opacity)
        persistUpdate(for: annotation)
        parent?.markDocumentEdited()
        refreshAnnotationModels()
    }

    func updateAnnotationContents(_ annotation: PDFAnnotation, contents: String) {
        annotation.contents = contents
        persistUpdate(for: annotation)
        parent?.markDocumentEdited()
        refreshAnnotationModels()
    }

    func addAreaAnnotation(bounds: CGRect, page: PDFPage, pageIndex: Int, color: NSColor) {
        let annotation = PDFAnnotation.rectangle(
            bounds: bounds,
            color: color,
            fillColor: nil,
            lineWidth: 3.0
        )
        page.addAnnotation(annotation)
        persistToStore(
            pdfAnnotation: annotation,
            pageIndex: pageIndex,
            selectedText: nil,
            existingId: nil
        )
        parent?.markDocumentEdited()
        refreshAnnotationModels()
    }

    // MARK: - Annotations Model List

    func refreshAnnotationModels() {
        guard let doc = pdfDocument else {
            annotationModels = []
            return
        }

        var models: [AnnotationModel] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for annotation in page.annotations {
                // Skip widget (form field) annotations
                if annotation.type == "Widget" { continue }
                models.append(AnnotationModel(from: annotation, pageIndex: i))
            }
        }
        annotationModels = models
    }

    func annotation(at pageIndex: Int, bounds: CGRect) -> PDFAnnotation? {
        guard let doc = pdfDocument,
              let page = doc.page(at: pageIndex) else { return nil }
        return page.annotation(at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    // MARK: - Flatten All Annotations

    func flattenAll() {
        guard let doc = pdfDocument else { return }
        doc.flattenAnnotations()
        parent?.markDocumentEdited()
        refreshAnnotationModels()
    }

    // MARK: - Persistence Helpers

    /// Persist (or re-persist) a PDFAnnotation to the database.
    private func persistToStore(
        pdfAnnotation: PDFAnnotation,
        pageIndex: Int,
        selectedText: String?,
        existingId: String?
    ) {
        guard let store = annotationStore,
              let attId = attachmentId,
              let itmId = itemId else { return }

        let id = existingId ?? UUID().uuidString
        let key = existingId != nil ? nil : AnnotationStore.generateKey()
        let now = Date().iso8601String

        // Encode position
        var quadPts: [[CGFloat]]? = nil
        if let qp = pdfAnnotation.value(forAnnotationKey: .quadPoints) as? [NSValue] {
            quadPts = qp.map { val in
                let pt = val.pointValue
                return [pt.x, pt.y]
            }
        }
        let position = PDFAnnotationPosition(
            pageIndex: pageIndex,
            bounds: pdfAnnotation.bounds,
            quadPoints: quadPts
        )
        guard let positionJson = position.toJSON() else { return }

        // Encode style
        let style = AnnotationStyle(
            lineWidth: pdfAnnotation.border?.lineWidth,
            opacity: pdfAnnotation.color.alphaComponent,
            fontName: nil,
            fontSize: nil,
            interiorColorHex: pdfAnnotation.interiorColor?.hexString
        )
        let styleJson = style.toJSON()

        // Map PDFAnnotation type to canonical type string
        let annotationType = mapAnnotationType(pdfAnnotation.type)

        // Compute sort index
        let pageHeight = pdfAnnotation.page?.bounds(for: .mediaBox).height ?? 792
        let sortIndex = AnnotationStore.makeSortIndex(
            pageIndex: pageIndex,
            bounds: pdfAnnotation.bounds,
            pageHeight: pageHeight
        )

        // Build or update record
        let existingRecord = existingId.flatMap { store.fetch(id: $0) }
        let record = AnnotationRecord(
            id: id,
            userId: localUserId,
            itemId: itmId,
            attachmentId: attId,
            key: existingRecord?.key ?? key ?? AnnotationStore.generateKey(),
            type: annotationType,
            authorName: nil,
            text: selectedText ?? existingRecord?.text,
            comment: pdfAnnotation.contents ?? existingRecord?.comment,
            color: pdfAnnotation.color.hexString,
            pageLabel: "\(pageIndex + 1)",
            sortIndex: sortIndex,
            positionKind: "pdf",
            positionJson: positionJson,
            styleJson: styleJson,
            source: existingRecord?.source ?? "oakreader",
            sourceKey: existingRecord?.sourceKey,
            isExternal: existingRecord?.isExternal ?? false,
            createdAt: existingRecord?.createdAt ?? now,
            updatedAt: now,
            deletedAt: nil
        )

        store.upsert(record)
        registerMapping(pdfAnnotation, id: id)
    }

    /// Convenience: persist an update for an existing annotation already in the view.
    private func persistUpdate(for annotation: PDFAnnotation) {
        guard let page = annotation.page, let doc = pdfDocument else { return }
        let pageIndex = doc.index(for: page)
        persistToStore(
            pdfAnnotation: annotation,
            pageIndex: pageIndex,
            selectedText: nil,
            existingId: persistentId(for: annotation)
        )
    }

    /// Map PDFKit type string to canonical annotation type.
    private func mapAnnotationType(_ pdfType: String?) -> String {
        switch pdfType {
        case "Highlight": return "highlight"
        case "Underline": return "underline"
        case "StrikeOut": return "strikethrough"
        case "FreeText": return "text"
        case "Text": return "note"
        case "Ink": return "ink"
        case "Line": return "line"
        case "Square": return "square"
        case "Circle": return "circle"
        case "Stamp": return "stamp"
        default: return pdfType?.lowercased() ?? "unknown"
        }
    }
}
