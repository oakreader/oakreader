import Foundation
import GRDB

/// Stateless CRUD service for AI Studio artifacts against the `studio_artifacts`
/// table. Mirrors `AnnotationStore`. Maps between the GRDB `StudioArtifactRecord`
/// and the domain `StudioArtifact`.
struct StudioArtifactStore {
    let database: CatalogDatabase

    // MARK: - Fetch

    /// Load all artifacts for an item, newest first.
    func fetch(itemId: String) -> [StudioArtifact] {
        do {
            let records = try database.dbQueue.read { db in
                try StudioArtifactRecord
                    .filter(StudioArtifactRecord.CodingKeys.itemId == itemId)
                    .order(StudioArtifactRecord.CodingKeys.createdAt.desc)
                    .fetchAll(db)
            }
            return records.compactMap(Self.domain(from:))
        } catch {
            Log.error(Log.store, "StudioArtifactStore.fetch failed: \(error)")
            return []
        }
    }

    // MARK: - Upsert

    @discardableResult
    func upsert(_ artifact: StudioArtifact) -> Bool {
        do {
            var record = Self.record(from: artifact)
            try database.dbQueue.write { db in
                try record.save(db)
            }
            return true
        } catch {
            Log.error(Log.store, "StudioArtifactStore.upsert failed: \(error)")
            return false
        }
    }

    // MARK: - Delete

    @discardableResult
    func delete(id: String) -> Bool {
        do {
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM studio_artifacts WHERE id = ?", arguments: [id])
            }
            return true
        } catch {
            Log.error(Log.store, "StudioArtifactStore.delete failed: \(error)")
            return false
        }
    }

    // MARK: - Mapping

    static func domain(from record: StudioArtifactRecord) -> StudioArtifact? {
        guard let kind = StudioArtifactKind(rawValue: record.kind) else { return nil }
        let params = (record.paramsJson.data(using: .utf8))
            .flatMap { try? JSONDecoder().decode(StudioGenerationParams.self, from: $0) }
            ?? .default
        return StudioArtifact(
            id: record.id,
            itemId: record.itemId,
            kind: kind,
            title: record.title,
            body: record.body,
            params: params,
            assetPath: record.assetPath,
            createdAt: Date(iso8601String: record.createdAt) ?? Date(),
            updatedAt: Date(iso8601String: record.updatedAt) ?? Date()
        )
    }

    static func record(from artifact: StudioArtifact) -> StudioArtifactRecord {
        let paramsJson = (try? JSONEncoder().encode(artifact.params))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return StudioArtifactRecord(
            id: artifact.id,
            userId: localUserId,
            itemId: artifact.itemId,
            kind: artifact.kind.rawValue,
            title: artifact.title,
            body: artifact.body,
            paramsJson: paramsJson,
            assetPath: artifact.assetPath,
            createdAt: artifact.createdAt.iso8601String,
            updatedAt: artifact.updatedAt.iso8601String
        )
    }
}
