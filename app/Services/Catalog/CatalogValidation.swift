import Foundation

/// Asking the core whether a database file is one it can open.
///
/// The schema has one owner, and it is not this side any more. Anything that
/// needs to know whether a `library.sqlite` is usable — a restore, before it
/// swaps a backup in — has to ask the side that would have to live with it.
enum CatalogValidation {
    static func check(path: String) async -> (ok: Bool, error: String?) {
        do {
            let result = try await NodeBackend.shared.call(
                RPC.Method.catalogValidate, params: RPC.CatalogValidateParams(path: path),
                as: RPC.CatalogValidateResult.self)
            return (result.ok, result.error)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
