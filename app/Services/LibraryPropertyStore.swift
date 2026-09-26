import Foundation
import AppKit
import GRDB

extension LibraryStore {
    // MARK: - Properties

    var properties: [PropertyDefinition] {
        _ = revision
        if let cached = propertiesCache, cached.revision == revision {
            return cached.properties
        }
        let result = (try? fetchAllProperties()) ?? []
        propertiesCache = (revision: revision, properties: result)
        return result
    }

    func fetchAllProperties() throws -> [PropertyDefinition] {
        try database.dbQueue.read { db in
            let propRecords = try PropertyRecord.order(PropertyRecord.CodingKeys.position).fetchAll(db)
            let optionRecords = try PropertyOptionRecord.order(PropertyOptionRecord.CodingKeys.position).fetchAll(db)

            var optionsByProperty: [String: [PropertyOption]] = [:]
            for opt in optionRecords {
                optionsByProperty[opt.propertyId, default: []].append(PropertyOption(record: opt))
            }

            return propRecords.map { prop in
                PropertyDefinition(record: prop, options: optionsByProperty[prop.id] ?? [])
            }
        }
    }

    @discardableResult
    func createProperty(name: String, type: PropertyType, icon: String = "tag") -> PropertyDefinition? {
        let id = UUID().uuidString
        let record = PropertyRecord(
            id: id,
            name: name,
            type: type.rawValue,
            icon: icon,
            position: properties.count,
            isSystem: false
        )
        do {
            try database.dbQueue.write { db in
                var r = record
                try r.insert(db)
            }
            invalidate()
            return PropertyDefinition(record: record)
        } catch {
            Log.error(Log.store, "createProperty failed: \(error)")
            return nil
        }
    }

    func deleteProperty(_ property: PropertyDefinition) {
        guard !property.isSystem else { return }
        do {
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM properties WHERE id = ?", arguments: [property.id.uuidString])
            }
            invalidate()
        } catch {
            Log.error(Log.store, "deleteProperty failed: \(error)")
        }
    }

    @discardableResult
    func addPropertyOption(propertyId: UUID, name: String, colorHex: String) -> PropertyOption? {
        let optId = UUID().uuidString
        let record = PropertyOptionRecord(
            id: optId,
            propertyId: propertyId.uuidString,
            name: name,
            colorHex: colorHex,
            position: 0  // Will be appended at end
        )
        do {
            try database.dbQueue.write { db in
                // Get next position
                let maxPos = try Int.fetchOne(db, sql: """
                    SELECT MAX(position) FROM property_options WHERE property_id = ?
                """, arguments: [propertyId.uuidString]) ?? -1
                var r = record
                r.position = maxPos + 1
                try r.insert(db)
            }
            invalidate()
            return PropertyOption(record: record)
        } catch {
            Log.error(Log.store, "addPropertyOption failed: \(error)")
            return nil
        }
    }

    func removePropertyOption(_ option: PropertyOption) {
        do {
            try database.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM property_options WHERE id = ?", arguments: [option.id.uuidString])
            }
            invalidate()
        } catch {
            Log.error(Log.store, "removePropertyOption failed: \(error)")
        }
    }

    func renamePropertyOption(_ option: PropertyOption, to newName: String) {
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE property_options SET name = ? WHERE id = ?",
                    arguments: [newName, option.id.uuidString]
                )
            }
            invalidate()
        } catch {
            Log.error(Log.store, "renamePropertyOption failed: \(error)")
        }
    }

    func updatePropertyOptionColor(_ option: PropertyOption, colorHex: String) {
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE property_options SET color_hex = ? WHERE id = ?",
                    arguments: [colorHex, option.id.uuidString]
                )
            }
            invalidate()
        } catch {
            Log.error(Log.store, "updatePropertyOptionColor failed: \(error)")
        }
    }

    /// Set a select-type property value (adds option_id to item_property_values).
    /// For multi_select: adds if not already present.
    /// For single_select: replaces existing value.
    func setItemSelectValue(item: LibraryItem, property: PropertyDefinition, option: PropertyOption) {
        do {
            try database.dbQueue.write { db in
                if property.type == .singleSelect {
                    // Remove existing value for this property
                    try db.execute(
                        sql: "DELETE FROM item_property_values WHERE item_id = ? AND property_id = ?",
                        arguments: [item.id.uuidString, property.id.uuidString]
                    )
                } else {
                    // multi_select: check if already assigned
                    let exists = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM item_property_values
                        WHERE item_id = ? AND property_id = ? AND option_id = ?
                    """, arguments: [item.id.uuidString, property.id.uuidString, option.id.uuidString]) ?? 0
                    if exists > 0 { return }
                }

                var record = ItemPropertyValueRecord(
                    id: UUID().uuidString,
                    itemId: item.id.uuidString,
                    propertyId: property.id.uuidString,
                    optionId: option.id.uuidString,
                    textValue: nil
                )
                try record.insert(db)
            }
            invalidate()
        } catch {
            Log.error(Log.store, "setItemSelectValue failed: \(error)")
        }
    }

    /// Remove a select-type property value (removes the option from the item).
    func removeItemSelectValue(item: LibraryItem, property: PropertyDefinition, option: PropertyOption) {
        do {
            try database.dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM item_property_values WHERE item_id = ? AND property_id = ? AND option_id = ?",
                    arguments: [item.id.uuidString, property.id.uuidString, option.id.uuidString]
                )
            }
            invalidate()
        } catch {
            Log.error(Log.store, "removeItemSelectValue failed: \(error)")
        }
    }

    /// Set a text/number property value.
    func setItemTextValue(item: LibraryItem, property: PropertyDefinition, value: String) {
        do {
            try database.dbQueue.write { db in
                // Remove existing
                try db.execute(
                    sql: "DELETE FROM item_property_values WHERE item_id = ? AND property_id = ?",
                    arguments: [item.id.uuidString, property.id.uuidString]
                )
                if !value.isEmpty {
                    var record = ItemPropertyValueRecord(
                        id: UUID().uuidString,
                        itemId: item.id.uuidString,
                        propertyId: property.id.uuidString,
                        optionId: nil,
                        textValue: value
                    )
                    try record.insert(db)
                }
            }
            invalidate()
        } catch {
            Log.error(Log.store, "setItemTextValue failed: \(error)")
        }
    }

}
