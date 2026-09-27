import Foundation

/// Properties — tag and status columns — read from and written to the core.
///
/// How many values an item may hold is decided by the property's type, and that
/// decision lives in the core rather than here: a multi-select appends, a
/// single-select replaces. The shell sends the option and lets the core apply
/// the rule, so the two sides cannot disagree about what a second tag means.
enum PropertyCatalog {
    static func list() async -> [CatalogProperty] {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.propertiesList, params: RPC.PropertiesListParams(),
                as: RPC.PropertiesListResult.self)
            return result.properties ?? []
        } catch {
            Log.error(Log.store, "properties/list failed: \(error.localizedDescription)")
            return []
        }
    }

    static func upsertOption(_ option: CatalogPropertyOption) async {
        await perform(RPC.Method.propertiesUpsertOption,
                      RPC.PropertiesUpsertOptionParams(option: option))
    }

    static func deleteOption(id: String) async {
        await perform(RPC.Method.propertiesDeleteOption,
                      RPC.PropertiesDeleteOptionParams(id: id))
    }

    static func addSelectValue(itemId: String, propertyId: String, optionId: String) async {
        await perform(RPC.Method.propertiesAddSelectValue,
                      RPC.PropertiesAddSelectValueParams(
                        valueId: UUID().uuidString, itemId: itemId,
                        propertyId: propertyId, optionId: optionId))
    }

    static func removeSelectValue(itemId: String, propertyId: String, optionId: String) async {
        await perform(RPC.Method.propertiesRemoveSelectValue,
                      RPC.PropertiesRemoveSelectValueParams(
                        itemId: itemId, propertyId: propertyId, optionId: optionId))
    }

    private static func perform<P: Encodable>(_ method: String, _ params: P) async {
        do {
            try await NodeBackend.shared.call(method, params: params)
        } catch {
            Log.error(Log.store, "\(method) failed: \(error.localizedDescription)")
        }
    }
}
