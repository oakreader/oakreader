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

        let data = key.data(using: .utf8)!

        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
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
