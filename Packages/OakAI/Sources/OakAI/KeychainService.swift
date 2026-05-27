import Foundation
import Security

public enum KeychainService: Sendable {
    private static let servicePrefix = "com.oakreader.apikey"

    // MARK: - String-based API (primary)

    public static func apiKey(forProviderId providerId: String) -> String? {
        let service = "\(servicePrefix).\(providerId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func setAPIKey(_ key: String, forProviderId providerId: String) -> Bool {
        let service = "\(servicePrefix).\(providerId)"
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Skill Environment Variables

    private static let skillEnvPrefix = "com.oakreader.skill.env"

    /// Read a skill environment variable from Keychain.
    public static func skillEnvValue(skill: String, envName: String) -> String? {
        let service = "\(skillEnvPrefix).\(skill).\(envName)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Store a skill environment variable in Keychain.
    @discardableResult
    public static func setSkillEnvValue(_ value: String, skill: String, envName: String) -> Bool {
        let service = "\(skillEnvPrefix).\(skill).\(envName)"
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]

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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Deprecated AIProvider-based API (delegates to string-based)

    @available(*, deprecated, message: "Use apiKey(forProviderId:) instead")
    public static func apiKey(for provider: AIProvider) -> String? {
        apiKey(forProviderId: provider.rawValue)
    }

    @available(*, deprecated, message: "Use setAPIKey(_:forProviderId:) instead")
    @discardableResult
    public static func setAPIKey(_ key: String, for provider: AIProvider) -> Bool {
        setAPIKey(key, forProviderId: provider.rawValue)
    }

    @available(*, deprecated, message: "Use deleteAPIKey(forProviderId:) instead")
    public static func deleteAPIKey(for provider: AIProvider) {
        deleteAPIKey(forProviderId: provider.rawValue)
    }
}
