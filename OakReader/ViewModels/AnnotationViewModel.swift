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

    // MARK: - Highlight / Underline / Strikethrough

    func addHighlight(for selection: PDFSelection) {
        addTextMarkup(for: selection, kind: .highlight)
    }

    func addUnderline(for selection: PDFSelection) {
        addTextMarkup(for: selection, kind: .underline)
    }

    /// Create a note: a highlighted markup carrying an (initially empty) comment,
    /// so it draws a clickable marker. Returns the new markup's id so the caller
    /// can open the comment editor anchored to it.
    @discardableResult
    func addNote(for selection: PDFSelection) -> String? {
        addTextMarkup(for: selection, kind: .highlight, comment: "")
    }

    /// Persist a text markup to the DB and add it to the overlay — *not* baked
    /// into the PDF. The original file stays untouched (no `markDocumentEdited`),
    /// the DB is the source of truth, and the overlay draws it with a stable
    /// color. See PDFMarkupOverlay for the rationale. Returns the id of the last
    /// created markup (notes are single-selection, so this is the note's id).
    @discardableResult
    private func addTextMarkup(for selection: PDFSelection, kind: PDFMarkupKind, comment: String? = nil) -> String? {
        guard let doc = pdfDocument, let overlay = parent?.markupOverlay else { return nil }
        // Highlights read as a translucent marker; underline/strikethrough are
        // drawn as opaque strokes. The overlay owns the blend, so we store the
        // marker's intended alpha rather than pre-baking it into a fill.
        let alpha = kind == .highlight ? opacity * 0.5 : opacity
        let color = strokeColor.withAlphaComponent(alpha)
        var lastId: String?

        for page in selection.pages {
            let pageIndex = doc.index(for: page)

            // Per-line quads for precise text coverage.
            var quads: [CGRect] = []
            var quadPoints: [[CGFloat]] = []
            for lineSel in selection.selectionsByLine() {
                let lb = lineSel.bounds(for: page)
                guard lb.width > 0, lb.height > 0 else { continue }
                quads.append(lb)
                quadPoints.append([lb.minX, lb.minY])
                quadPoints.append([lb.maxX, lb.minY])
                quadPoints.append([lb.minX, lb.maxY])
                quadPoints.append([lb.maxX, lb.maxY])
            }
            guard !quads.isEmpty else { continue }

            let id = UUID().uuidString
            persistOverlayMarkup(
                id: id,
                kind: kind,
                pageIndex: pageIndex,
                bounds: selection.bounds(for: page),
                quadPoints: quadPoints,
                color: color,
                selectedText: selection.string,
                comment: comment
            )
            overlay.add(
                PDFTextMarkup(id: id, kind: kind, quads: quads, color: color, text: selection.string, comment: comment),
                page: pageIndex
            )
            lastId = id
        }
        refreshAnnotationModels()
        return lastId
    }

    /// Switch a markup's style (highlight ↔ underline) from the note editor.
    func updateOverlayMarkupKind(id: String, kind: PDFMarkupKind) {
        guard let store = annotationStore, let record = store.fetch(id: id) else { return }
        var updated = record
        updated.type = kind.rawValue
        updated.updatedAt = Date().iso8601String
        store.upsert(updated)
        parent?.markupOverlay.updateKind(id: id, kind: kind)
        refreshAnnotationModels()
    }

    /// Save (or clear) a note's comment. An empty/whitespace comment turns the
    /// note back into a plain highlight (marker disappears).
    func updateOverlayMarkupComment(id: String, comment: String) {
        guard let store = annotationStore, let record = store.fetch(id: id) else { return }
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored: String? = trimmed.isEmpty ? nil : comment
        var updated = record
        updated.comment = stored
        updated.updatedAt = Date().iso8601String
        store.upsert(updated)
        parent?.markupOverlay.updateComment(id: id, comment: stored)
        refreshAnnotationModels()
        NotificationCenter.default.post(name: .commentsDidChange, object: parent)
    }

    /// Delete an overlay markup by its DB id.
    func deleteOverlayMarkup(id: String) {
        annotationStore?.softDelete(id: id)
        parent?.markupOverlay.remove(id: id)
        refreshAnnotationModels()
        NotificationCenter.default.post(name: .commentsDidChange, object: parent)
    }

    /// Recolor an overlay markup, preserving its current alpha.
    func updateOverlayMarkupColor(id: String, color: NSColor) {
        guard let store = annotationStore, let record = store.fetch(id: id) else { return }
        let alpha = AnnotationStyle.fromJSON(record.styleJson ?? "")?.opacity ?? color.alphaComponent
        let newColor = color.withAlphaComponent(alpha)
        var updated = record
        updated.color = newColor.hexString
        updated.updatedAt = Date().iso8601String
        store.upsert(updated)
        parent?.markupOverlay.updateColor(id: id, color: newColor)
        refreshAnnotationModels()
    }

    /// Load all `pdf-overlay` markups for this attachment from the DB and hand
    /// them to the overlay controller. Idempotent — safe to call on every open.
    func loadOverlayMarkups() {
        guard let store = annotationStore,
              let attId = attachmentId,
              let overlay = parent?.markupOverlay else { return }

        // Greenfield: drop any old baked text markups so they don't double-draw
        // against the overlay. We don't migrate them — overlay + DB is the only model.
        stripBakedTextMarkups()

        let records = store.fetch(attachmentId: attId)
            .filter { $0.positionKind == "pdf-overlay" && $0.deletedAt == nil }

        var byPage: [Int: [PDFTextMarkup]] = [:]
        for record in records {
            guard let position = PDFAnnotationPosition.fromJSON(record.positionJson),
                  let kind = PDFMarkupKind(rawValue: record.type) else { continue }
            let opacity = AnnotationStyle.fromJSON(record.styleJson ?? "")?.opacity ?? 1.0
            let baseColor = NSColor(hex: record.color) ?? PDFDefaults.annotationDefaultColor
            let color = baseColor.withAlphaComponent(opacity)
            let markup = PDFTextMarkup(
                id: record.id,
                kind: kind,
                quads: quadRects(from: position),
                color: color,
                text: record.text,
                comment: record.comment
            )
            byPage[position.pageIndex, default: []].append(markup)
        }
        overlay.load(byPage)
        refreshAnnotationModels()
    }

    /// Remove any text-markup annotations baked into the PDF file so they don't
    /// double-draw against the overlay. The file is never rewritten, so this is
    /// just an in-memory cleanup; shapes/ink/notes are left untouched.
    private func stripBakedTextMarkups() {
        guard let doc = pdfDocument else { return }
        let nativeMarkupTypes: Set<String> = ["Highlight", "Underline", "StrikeOut"]
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            for annotation in page.annotations where nativeMarkupTypes.contains(annotation.type ?? "") {
                page.removeAnnotation(annotation)
            }
        }
    }

    /// Reconstruct per-line rects from stored quad points (4 points per line:
    /// bottom-left, bottom-right, top-left, top-right). Falls back to bounds.
    private func quadRects(from position: PDFAnnotationPosition) -> [CGRect] {
        guard let qp = position.quadPoints, qp.count >= 4 else { return [position.bounds] }
        var rects: [CGRect] = []
        var i = 0
        while i + 3 < qp.count {
            let pts = (0...3).map { CGPoint(x: qp[i + $0][0], y: qp[i + $0][1]) }
            let minX = min(pts[0].x, pts[2].x)
            let maxX = max(pts[1].x, pts[3].x)
            let minY = min(pts[0].y, pts[1].y)
            let maxY = max(pts[2].y, pts[3].y)
            rects.append(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            i += 4
        }
        return rects.isEmpty ? [position.bounds] : rects
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
        var models: [AnnotationModel] = []

        // Native annotations still baked into the PDF (shapes, ink, notes, …).
        if let doc = pdfDocument {
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                for annotation in page.annotations {
                    // Skip widget (form field) annotations
                    if annotation.type == "Widget" { continue }
                    models.append(AnnotationModel(from: annotation, pageIndex: i))
                }
            }
        }

        // DB-backed text-markup highlights (not present in page.annotations).
        if let overlay = parent?.markupOverlay {
            for entry in overlay.allMarkups() {
                models.append(AnnotationModel(overlayMarkup: entry.markup, pageIndex: entry.pageIndex))
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

    /// Persist a text-markup overlay (`positionKind: "pdf-overlay"`) — color +
    /// alpha + per-line quad points. This is the single source of truth for
    /// overlay highlights; nothing is written into the PDF file.
    private func persistOverlayMarkup(
        id: String,
        kind: PDFMarkupKind,
        pageIndex: Int,
        bounds: CGRect,
        quadPoints: [[CGFloat]],
        color: NSColor,
        selectedText: String?,
        comment: String? = nil
    ) {
        guard let store = annotationStore,
              let attId = attachmentId,
              let itmId = itemId else { return }

        let position = PDFAnnotationPosition(pageIndex: pageIndex, bounds: bounds, quadPoints: quadPoints)
        guard let positionJson = position.toJSON() else { return }

        // Alpha lives in styleJson.opacity (the hex color drops alpha), so the
        // marker's translucency round-trips correctly on reload.
        let style = AnnotationStyle(
            lineWidth: nil,
            opacity: color.alphaComponent,
            fontName: nil,
            fontSize: nil,
            interiorColorHex: nil
        )

        let pageHeight = pdfDocument?.page(at: pageIndex)?.bounds(for: .mediaBox).height ?? 792
        let now = Date().iso8601String
        let record = AnnotationRecord(
            id: id,
            userId: localUserId,
            itemId: itmId,
            attachmentId: attId,
            key: AnnotationStore.generateKey(),
            type: kind.rawValue,
            authorName: nil,
            text: selectedText,
            comment: comment,
            color: color.hexString,
            pageLabel: "\(pageIndex + 1)",
            sortIndex: AnnotationStore.makeSortIndex(pageIndex: pageIndex, bounds: bounds, pageHeight: pageHeight),
            positionKind: "pdf-overlay",
            positionJson: positionJson,
            styleJson: style.toJSON(),
            source: "oakreader",
            sourceKey: nil,
            createdAt: now,
            updatedAt: now,
            deletedAt: nil
        )
        store.upsert(record)
    }

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
