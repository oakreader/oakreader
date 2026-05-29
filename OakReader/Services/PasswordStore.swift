import Foundation
import Security

/// A saved web login.
struct WebCredential: Identifiable, Hashable {
    var id: String { "\(host)\u{1}\(username)" }
    let host: String
    let username: String
    let password: String
}

/// Keychain-backed password manager for the live web browser.
///
/// Credentials are stored as `kSecClassInternetPassword` items keyed by host
/// (`kSecAttrServer`) + username (`kSecAttrAccount`), so they're isolated per
/// site and visible in Keychain Access. This mirrors how every third-party
/// WKWebView browser handles passwords — the system autofill UI is reserved for
/// Safari, so we roll our own. Same Keychain approach as `CredentialResolver`.
enum PasswordStore {
    /// Save (or update) a credential for a host.
    @discardableResult
    static func save(host: String, username: String, password: String) -> Bool {
        guard !host.isEmpty, !username.isEmpty, !password.isEmpty else { return false }

        // Update in place if the (host, username) pair already exists.
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: username,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8)
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        // Otherwise insert a new item.
        var addQuery = query
        addQuery[kSecValueData as String] = Data(password.utf8)
        addQuery[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    /// All saved credentials for a host (most sites have one).
    static func credentials(for host: String) -> [WebCredential] {
        guard !host.isEmpty else { return [] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }

        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let password = String(data: data, encoding: .utf8) else { return nil }
            return WebCredential(host: host, username: account, password: password)
        }
    }

    /// Whether a stored password differs from `password` (or is absent) — i.e. worth prompting to save.
    static func needsSave(host: String, username: String, password: String) -> Bool {
        let existing = credentials(for: host).first { $0.username == username }
        return existing?.password != password
    }

    @discardableResult
    static func delete(host: String, username: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrAccount as String: username,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
