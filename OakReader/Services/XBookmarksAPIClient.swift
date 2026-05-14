import Foundation

/// HTTP client for the X (Twitter) API v2 — user lookup and bookmarks.
enum XBookmarksAPIClient {

    // MARK: - User Lookup

    struct UserResponse: Decodable {
        struct Data: Decodable {
            let id: String
            let username: String
            let name: String
        }
        let data: Data
    }

    /// Look up the authenticated user's ID and username.
    static func lookupUser(bearerToken: String) async throws -> UserResponse.Data {
        let url = URL(string: "https://api.x.com/2/users/me")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 401 || statusCode == 403 {
            throw SyncError.authenticationFailed
        }
        guard statusCode == 200 else {
            throw SyncError.apiFailed(statusCode: statusCode)
        }
        let decoded = try JSONDecoder().decode(UserResponse.self, from: data)
        return decoded.data
    }

    // MARK: - Bookmarks

    struct BookmarksResponse: Decodable {
        struct Tweet: Decodable {
            let id: String
            let text: String
            let createdAt: String?
            let authorId: String?

            enum CodingKeys: String, CodingKey {
                case id, text
                case createdAt = "created_at"
                case authorId = "author_id"
            }
        }

        struct Meta: Decodable {
            let resultCount: Int?
            let nextToken: String?

            enum CodingKeys: String, CodingKey {
                case resultCount = "result_count"
                case nextToken = "next_token"
            }
        }

        let data: [Tweet]?
        let meta: Meta?
    }

    /// Fetch a page of bookmarks for the given user.
    static func fetchBookmarks(
        bearerToken: String,
        userId: String,
        paginationToken: String? = nil
    ) async throws -> BookmarksResponse {
        var components = URLComponents(string: "https://api.x.com/2/users/\(userId)/bookmarks")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "max_results", value: "100"),
            URLQueryItem(name: "tweet.fields", value: "created_at,author_id,text"),
        ]
        if let paginationToken {
            queryItems.append(URLQueryItem(name: "pagination_token", value: paginationToken))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 401 || statusCode == 403 {
            throw SyncError.authenticationFailed
        }
        guard statusCode == 200 else {
            throw SyncError.apiFailed(statusCode: statusCode)
        }
        return try JSONDecoder().decode(BookmarksResponse.self, from: data)
    }
}
