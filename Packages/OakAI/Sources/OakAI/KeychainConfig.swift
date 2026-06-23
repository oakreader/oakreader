import Foundation
import Security

/// Shared Keychain configuration for every OakAI credential store
/// (`KeychainService`, `OAuthTokenStore`).
///
/// All items are written to the **data-protection keychain** and scoped to a
/// team-stable access group rather than the file-based login keychain's
/// per-binary ACL. That distinction is the whole point: a file-based keychain
/// item's ACL is bound to the exact code signature that created it, so the
/// moment the app is rebuilt under a different signing identity (or the dev
/// `.dev` build is re-signed) macOS treats it as a different program and denies
/// `SecItemCopyMatching` — the read returns `nil` and a saved API key looks
/// like it "disappeared". Scoping to `keychain-access-groups` (which resolves
/// to `<TeamID>.com.oakreader.keys`) binds items to the team entitlement
/// instead, so credentials survive rebuilds and signing-identity changes.
enum KeychainConfig {
    /// Must stay in sync with the `keychain-access-groups` entitlement
    /// (`$(AppIdentifierPrefix)com.oakreader.keys`). `AppIdentifierPrefix`
    /// expands to the team ID, which is `5Y27G7B6D8` for both Debug and Release.
    static let accessGroup = "5Y27G7B6D8.com.oakreader.keys"

    /// Adds the access group + data-protection-keychain flag every query must
    /// carry so reads and writes target the same keychain.
    ///
    /// In DEBUG, ad-hoc-signed dev builds carry no team prefix and would be
    /// rejected by the access group, so we fall back to the local file keychain.
    static func scoped(_ query: [String: Any]) -> [String: Any] {
        var q = query
        #if !DEBUG
        q[kSecAttrAccessGroup as String] = accessGroup
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }
}
