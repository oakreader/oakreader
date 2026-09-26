import Foundation

extension LibraryStore {
    // MARK: - Properties

    /// The property definitions, filled by `refresh()` alongside the items.
    /// Synchronous for the same reason `items` is: view bodies read it.
    var properties: [PropertyDefinition] { loadedProperties }

    /// Create a property and return it optimistically.
    ///
    /// The write is fired rather than awaited, as everywhere else in this store:
    /// call sites are menu actions that cannot await, and `invalidate()` reloads
    /// behind them. The returned definition is what was sent, so a caller can
    /// select it immediately instead of waiting for the round trip.
    @discardableResult
    func createProperty(name: String, type: PropertyType, icon: String = "tag") -> PropertyDefinition? {
        let property = PropertyDefinition(
            record: PropertyRecord(
                id: UUID().uuidString,
                name: name,
                type: type.rawValue,
                icon: icon,
                position: properties.count,
                isSystem: false
            )
        )
        write { await PropertyCatalog.upsert(property.wire) }
        return property
    }

    func deleteProperty(_ property: PropertyDefinition) {
        guard !property.isSystem else { return }
        write { await PropertyCatalog.delete(id: property.id.uuidString) }
    }

    /// Append an option to a property. Position is the current count, which is
    /// where the old `MAX(position) + 1` query landed for a list with no gaps.
    @discardableResult
    func addPropertyOption(propertyId: UUID, name: String, colorHex: String) -> PropertyOption? {
        let position = properties.first { $0.id == propertyId }?.options.count ?? 0
        let option = PropertyOption(record: PropertyOptionRecord(
            id: UUID().uuidString,
            propertyId: propertyId.uuidString,
            name: name,
            colorHex: colorHex,
            position: position
        ))
        write { await PropertyCatalog.upsertOption(option.wire) }
        return option
    }

    func removePropertyOption(_ option: PropertyOption) {
        write { await PropertyCatalog.deleteOption(id: option.id.uuidString) }
    }

    func renamePropertyOption(_ option: PropertyOption, to newName: String) {
        var updated = option
        updated.name = newName
        write { await PropertyCatalog.upsertOption(updated.wire) }
    }

    func updatePropertyOptionColor(_ option: PropertyOption, colorHex: String) {
        var updated = option
        updated.colorHex = colorHex
        write { await PropertyCatalog.upsertOption(updated.wire) }
    }

    // MARK: - Item values

    /// Give an item one of a select property's options.
    ///
    /// Whether that replaces the item's previous choice or joins it is decided
    /// by the property's type, and the core decides it — a multi-select keeps
    /// both, a single-select keeps the latest.
    func setItemSelectValue(item: LibraryItem, property: PropertyDefinition, option: PropertyOption) {
        write {
            await PropertyCatalog.addSelectValue(
                itemId: item.id.uuidString,
                propertyId: property.id.uuidString,
                optionId: option.id.uuidString)
        }
    }

    func removeItemSelectValue(item: LibraryItem, property: PropertyDefinition, option: PropertyOption) {
        write {
            await PropertyCatalog.removeSelectValue(
                itemId: item.id.uuidString,
                propertyId: property.id.uuidString,
                optionId: option.id.uuidString)
        }
    }

    /// Set a text or number value. An empty string clears it.
    func setItemTextValue(item: LibraryItem, property: PropertyDefinition, value: String) {
        write {
            await PropertyCatalog.setTextValue(
                itemId: item.id.uuidString,
                propertyId: property.id.uuidString,
                value: value)
        }
    }

    /// Fire a write and reload once it lands, so the refresh sees it.
    private func write(_ body: @escaping () async -> Void) {
        Task { @MainActor in
            await body()
            invalidate()
        }
    }
}
