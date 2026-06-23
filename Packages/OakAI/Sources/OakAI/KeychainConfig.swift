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
    /// Release-only. Must stay in sync with the `keychain-access-groups`
    /// entitlement in `OakReader.entitlements` (`5Y27G7B6D8.com.oakreader.keys`).
    /// Debug builds ship `OakReader-dev.entitlements`, which omits that
    /// restricted key (so any team — or ad-hoc — can build), and therefore use
    /// the login keychain instead; see `scoped(_:)`.
    static let accessGroup = "5Y27G7B6D8.com.oakreader.keys"

    /// Targets the keychain that matches the build's entitlements.
    ///
    /// - Release: data-protection keychain scoped to the team-stable access
    ///   group, so credentials survive rebuilds and signing-identity changes.
    /// - Debug: the file-based login keychain (no access group, no
    ///   data-protection flag). The `-dev` entitlements omit
    ///   `keychain-access-groups`, so the data-protection keychain + access
    ///   group is unavailable; without that, setting `kSecAttrAccessGroup` would
    ///   fail with `errSecMissingEntitlement`. Keys persist across rebuilds as
    ///   long as the dev signing identity is stable; otherwise inject them via
    ///   the provider env vars (see `CredentialResolver`).
    static func scoped(_ query: [String: Any]) -> [String: Any] {
        var q = query
        #if !DEBUG
        q[kSecAttrAccessGroup as String] = accessGroup
        q[kSecUseDataProtectionKeychain as String] = true
        #endif
        return q
    }
}
