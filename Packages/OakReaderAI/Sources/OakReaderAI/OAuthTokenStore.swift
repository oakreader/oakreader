import Foundation
import Security

public enum OAuthTokenStore: Sendable {
    private static let servicePrefix = "com.oakreader.oauth"

    public struct TokenSet: Codable, Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresAt: Date?
        public let tokenType: String

        public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, tokenType: String = "Bearer") {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.tokenType = tokenType
        }

        public var isExpired: Bool {
            guard let expiresAt else { return false }
            return Date() >= expiresAt
        }
    }

    // MARK: - Access Token (convenience)

    public static func accessToken(for providerId: String) -> String? {
        guard let tokenSet = loadTokenSet(for: providerId) else { return nil }
        if tokenSet.isExpired { return nil }
        return tokenSet.accessToken
    }

    // MARK: - CRUD

    public static func store(_ tokenSet: TokenSet, for providerId: String) {
        let service = "\(servicePrefix).\(providerId)"
        guard let data = try? JSONEncoder().encode(tokenSet) else { return }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]

        // Try update first
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if status == errSecSuccess { return }

        // Add new
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    public static func loadTokenSet(for providerId: String) -> TokenSet? {
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
        return try? JSONDecoder().decode(TokenSet.self, from: data)
    }

    public static func delete(for providerId: String) {
        let service = "\(servicePrefix).\(providerId)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
