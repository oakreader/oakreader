import Foundation
import Security

public enum KeychainService: Sendable {
    private static let servicePrefix = "com.oakreader.apikey"

    // MARK: - String-based API (primary)

    public static func apiKey(forProviderId providerId: String) -> String? {
        let service = "\(servicePrefix).\(providerId)"
        let query = KeychainConfig.scoped([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func setAPIKey(_ key: String, forProviderId providerId: String) -> Bool {
        let service = "\(servicePrefix).\(providerId)"
        let baseQuery = KeychainConfig.scoped([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ])

        guard !key.isEmpty else {
            SecItemDelete(baseQuery as CFDictionary)
            return true
        }

        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = key.data(using: .utf8)!
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    public static func deleteAPIKey(forProviderId providerId: String) {
        let service = "\(servicePrefix).\(providerId)"
        let query = KeychainConfig.scoped([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ])
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Skill Environment Variables

    private static let skillEnvPrefix = "com.oakreader.skill.env"

    /// Read a skill environment variable from Keychain.
    public static func skillEnvValue(skill: String, envName: String) -> String? {
        let service = "\(skillEnvPrefix).\(skill).\(envName)"
        let query = KeychainConfig.scoped([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Store a skill environment variable in Keychain.
    @discardableResult
    public static func setSkillEnvValue(_ value: String, skill: String, envName: String) -> Bool {
        let service = "\(skillEnvPrefix).\(skill).\(envName)"
        let baseQuery = KeychainConfig.scoped([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ])

        guard !value.isEmpty else {
            SecItemDelete(baseQuery as CFDictionary)
            return true
        }

        SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = value.data(using: .utf8)!
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Remove a skill environment variable from Keychain.
    public static func deleteSkillEnvValue(skill: String, envName: String) {
        let service = "\(skillEnvPrefix).\(skill).\(envName)"
        let query = KeychainConfig.scoped([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ])
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Backend credentials (full Credential blobs)

    /// Credentials the AI sidecar stores through the shell, as opaque JSON.
    ///
    /// The sidecar's provider layer keys one credential per provider, and that
    /// credential is not always a bare string: an OAuth entry carries refresh /
    /// access / expiry, and an api-key entry can carry provider env (Cloudflare
    /// account ids and the like). So the item value is the serialized
    /// credential, not a key — `apiKey(forProviderId:)` above stays the older,
    /// narrower accessor and is still read as a fallback so a user who saved a
    /// key before this change keeps it.
    private static let credentialPrefix = "com.oakreader.credential"

    public static func credentialJSON(forProviderId providerId: String) -> String? {
        let query = KeychainConfig.scoped([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(credentialPrefix).\(providerId)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ])
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func setCredentialJSON(_ json: String, forProviderId providerId: String) -> Bool {
        let base = KeychainConfig.scoped([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(credentialPrefix).\(providerId)",
        ])
        SecItemDelete(base as CFDictionary)
        guard !json.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(json.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func deleteCredential(forProviderId providerId: String) {
        let query = KeychainConfig.scoped([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(credentialPrefix).\(providerId)",
        ])
        SecItemDelete(query as CFDictionary)
        // The legacy plain-key item is the read fallback, so a delete that left
        // it behind would resurrect the credential on the next read.
        deleteAPIKey(forProviderId: providerId)
    }

    /// Provider ids that have a stored credential, from either the blob items
    /// or the legacy plain-key ones.
    public static func credentialProviderIds() -> [String] {
        let query = KeychainConfig.scoped([
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ])
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }

        var ids = Set<String>()
        for item in items {
            guard let service = item[kSecAttrService as String] as? String else { continue }
            for prefix in ["\(credentialPrefix).", "\(servicePrefix)."] where service.hasPrefix(prefix) {
                ids.insert(String(service.dropFirst(prefix.count)))
            }
        }
        return ids.sorted()
    }
}
