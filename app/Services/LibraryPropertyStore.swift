import Foundation

extension LibraryStore {
    // MARK: - Properties

    /// The property definitions, filled by `refresh()` alongside the items.
    /// Synchronous for the same reason `items` is: view bodies read it.
    var properties: [PropertyDefinition] { loadedProperties }

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

    /// Fire a write and reload once it lands, so the refresh sees it.
    private func write(_ body: @escaping () async -> Void) {
        Task { @MainActor in
            await body()
            invalidate()
        }
    }
}
