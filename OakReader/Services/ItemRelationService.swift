import Foundation
import GRDB

/// Dublin Core–based relation types between library items.
enum ItemRelationType: String, CaseIterable {
    case related = "dc:relation"
    case replaces = "dc:replaces"
    case references = "dc:references"
}

/// CRUD service for item-to-item relations.
struct ItemRelationService {
    let database: CatalogDatabase

    /// Add a relation between two items. No-op if the relation already exists.
    func addRelation(
        sourceItemId: String,
        targetItemId: String,
        type: ItemRelationType
    ) throws {
        let now = Date().iso8601String
        try database.dbQueue.write { db in
            // Check for existing relation (UNIQUE constraint would also catch this)
            let exists = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM item_relations
                WHERE source_item_id = ? AND target_item_id = ? AND relation_type = ?
            """, arguments: [sourceItemId, targetItemId, type.rawValue]) ?? 0

            guard exists == 0 else { return }

            var record = ItemRelationRecord(
                id: UUID().uuidString,
                sourceItemId: sourceItemId,
                targetItemId: targetItemId,
                relationType: type.rawValue,
                createdAt: now
            )
            try record.insert(db)
        }
    }

    /// Remove a specific relation between two items.
    func removeRelation(
        sourceItemId: String,
        targetItemId: String,
        type: ItemRelationType
    ) throws {
        try database.dbQueue.write { db in
            try db.execute(sql: """
                DELETE FROM item_relations
                WHERE source_item_id = ? AND target_item_id = ? AND relation_type = ?
            """, arguments: [sourceItemId, targetItemId, type.rawValue])
        }
    }

    /// Fetch all items related to a given item (in either direction).
    func fetchRelatedItems(forItemId itemId: String) throws -> [(record: ItemRelationRecord, otherItemId: String)] {
        try database.dbQueue.read { db in
            let records = try ItemRelationRecord.fetchAll(db, sql: """
                SELECT * FROM item_relations
                WHERE source_item_id = ? OR target_item_id = ?
                ORDER BY created_at DESC
            """, arguments: [itemId, itemId])

            return records.map { record in
                let otherId = record.sourceItemId == itemId ? record.targetItemId : record.sourceItemId
                return (record: record, otherItemId: otherId)
            }
        }
    }
}
