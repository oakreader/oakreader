import Foundation
import Security

public enum KeychainService: Sendable {
    private static let servicePrefix = "com.oakreader.apikey"

    public static func apiKey(for provider: AIProvider) -> String? {
        let service = "\(servicePrefix).\(provider.rawValue)"
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
    public static func setAPIKey(_ key: String, for provider: AIProvider) -> Bool {
        let service = "\(servicePrefix).\(provider.rawValue)"
        // Delete existing
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard !key.isEmpty else { return true } // Just delete if empty

        let data = key.data(using: .utf8)!
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    public static func deleteAPIKey(for provider: AIProvider) {
        let service = "\(servicePrefix).\(provider.rawValue)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
