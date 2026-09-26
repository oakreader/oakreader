import Foundation

/// Annotation persistence, through the sidecar rather than GRDB.
///
/// What did *not* move: `AnnotationStore.makeSortIndex` and `generateKey`.
/// The first encodes a `CGRect` in PDF coordinate space, which is geometry and
/// therefore PDFKit's; the second is a random string with no storage in it.
/// Both stay here as pure functions on `AnnotationKeys` below, so the core
/// receives a `sortIndex` it never has to understand.
///
/// Latency shapes the API. Creating a highlight has to feel instant, and the
/// markup overlay already renders from memory — `refreshAnnotationModels`
/// reads the overlay, not the database. So callers update the overlay
/// synchronously and let the write follow: `save` and `delete` return
/// immediately, and only the reads await.
enum AnnotationCatalog {
    /// Live annotations on an attachment, in reading order. Tombstones excluded.
    static func list(attachmentId: String) async -> [CatalogAnnotation] {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.annotationsList,
                params: RPC.AnnotationsListParams(attachmentId: attachmentId),
                as: RPC.AnnotationsListResult.self)
            return result.annotations ?? []
        } catch {
            Log.error(Log.store, "annotations/list failed: \(error.localizedDescription)")
            return []
        }
    }

    /// One annotation by id, tombstoned or not. Nil when it does not exist.
    static func get(id: String) async -> CatalogAnnotation? {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.annotationsGet,
                params: RPC.AnnotationsGetParams(id: id),
                as: RPC.AnnotationsGetResult.self)
            return result.annotation
        } catch {
            Log.error(Log.store, "annotations/get failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Persist, without waiting. The overlay is already showing it.
    static func save(_ annotation: CatalogAnnotation) {
        Task {
            do {
                try await NodeBackend.shared.call(
                    RPC.Method.annotationsUpsert,
                    params: RPC.AnnotationsUpsertParams(annotation: annotation))
            } catch {
                Log.error(Log.store, "annotations/upsert failed: \(error.localizedDescription)")
            }
        }
    }

    /// Tombstone it, without waiting.
    ///
    /// Soft by default and deliberately so: the row survives as a tombstone so
    /// a later sync can tell "deleted" from "never existed". In this library
    /// 145 of 200 annotation rows are tombstones, so hard-deleting by default
    /// would quietly destroy history.
    static func delete(id: String, hard: Bool = false) {
        Task {
            do {
                try await NodeBackend.shared.call(
                    RPC.Method.annotationsDelete,
                    params: RPC.AnnotationsDeleteParams(
                        id: id, hard: hard, at: hard ? nil : Date().iso8601String))
            } catch {
                Log.error(Log.store, "annotations/delete failed: \(error.localizedDescription)")
            }
        }
    }
}

/// The two pieces of `AnnotationStore` that stayed in Swift, because neither
/// is storage: one is PDF geometry, the other is a random identifier.
enum AnnotationKeys {
    /// Random 8-character key, matching `CatalogDatabase.generateStorageKey()`.
    static func generate() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<8).map { _ in chars.randomElement()! })
    }

    /// Encode a sort index as `PPPPP|YYYYYY|XXXXXX`.
    ///
    /// The core orders by this string and never parses it — page layout is not
    /// the catalog's business.
    ///
    /// - Parameters:
    ///   - pageIndex: Zero-based page index.
    ///   - bounds: Annotation bounds in PDF coordinate space.
    ///   - pageHeight: Page height, used to invert Y so annotations sort
    ///     top-to-bottom (PDF's origin is bottom-left).
    static func sortIndex(pageIndex: Int, bounds: CGRect, pageHeight: CGFloat) -> String {
        let page = String(format: "%05d", pageIndex)
        let invertedY = max(0, pageHeight - bounds.maxY)
        let y = String(format: "%06d", Int(invertedY))
        let x = String(format: "%06d", Int(bounds.minX))
        return "\(page)|\(y)|\(x)"
    }
}
