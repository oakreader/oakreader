import Foundation

/// HTTP client for the GitHub REST API — user verification and starred repos.
enum GitHubStarsAPIClient {

    // MARK: - User Verification

    struct GitHubUser: Decodable {
        let login: String
        let id: Int
        let name: String?
    }

    /// Verify the token and return the authenticated user.
    static func verifyToken(_ token: String) async throws -> GitHubUser {
        let url = URL(string: "https://api.github.com/user")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 401 || statusCode == 403 {
            throw SyncError.authenticationFailed
        }
        guard statusCode == 200 else {
            throw SyncError.apiFailed(statusCode: statusCode)
        }
        return try JSONDecoder().decode(GitHubUser.self, from: data)
    }

    // MARK: - Starred Repos

    struct StarredRepo: Decodable {
        let id: Int
        let fullName: String
        let htmlUrl: String
        let description: String?
        let language: String?
        let stargazersCount: Int
        let topics: [String]?
        let owner: Owner

        struct Owner: Decodable {
            let login: String
            let avatarUrl: String

            enum CodingKeys: String, CodingKey {
                case login
                case avatarUrl = "avatar_url"
            }
        }

        enum CodingKeys: String, CodingKey {
            case id
            case fullName = "full_name"
            case htmlUrl = "html_url"
            case description, language
            case stargazersCount = "stargazers_count"
            case topics, owner
        }
    }

    // MARK: - README

    /// Fetch the raw README content for a repository. Returns nil if no README exists.
    static func fetchReadme(token: String, owner: String, repo: String) async -> String? {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/readme")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Request raw content directly instead of JSON-wrapped base64
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Fetch a single repository's metadata.
    static func fetchRepo(token: String, owner: String, repo: String) async -> StarredRepo? {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            return nil
        }
        return try? JSONDecoder().decode(StarredRepo.self, from: data)
    }

    /// Fetch the total number of starred repos for the authenticated user.
    /// Uses `per_page=1` and parses the `Link` header to extract the last page number.
    static func fetchStarredCount(token: String) async throws -> Int {
        var components = URLComponents(string: "https://api.github.com/user/starred")!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "1"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return 0
        }

        // Parse Link header: <...?page=42>; rel="last"
        if let link = httpResponse.value(forHTTPHeaderField: "Link"),
           let lastMatch = link.range(of: #"page=(\d+)>;\s*rel="last""#, options: .regularExpression) {
            let pageStr = link[lastMatch]
            if let numRange = pageStr.range(of: #"\d+"#, options: .regularExpression) {
                return Int(pageStr[numRange]) ?? 0
            }
        }

        // If no Link header, there's 0 or 1 starred repo
        let data = try await URLSession.shared.data(for: request).0
        let repos = try? JSONDecoder().decode([StarredRepo].self, from: data)
        return repos?.count ?? 0
    }

    /// Result of a single page fetch, including whether more pages exist.
    struct StarredPage {
        let repos: [StarredRepo]
        let hasNextPage: Bool
    }

    /// Fetch a page of starred repositories (sorted by most recently starred).
    /// Uses the `Link` header to determine whether more pages exist.
    static func fetchStarred(token: String, page: Int = 1) async throws -> StarredPage {
        var components = URLComponents(string: "https://api.github.com/user/starred")!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "sort", value: "created"),
            URLQueryItem(name: "direction", value: "desc"),
            URLQueryItem(name: "page", value: "\(page)"),
        ]

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let statusCode = httpResponse?.statusCode ?? 0

        if statusCode == 401 || statusCode == 403 {
            throw SyncError.authenticationFailed
        }
        guard statusCode == 200 else {
            throw SyncError.apiFailed(statusCode: statusCode)
        }

        let repos = try JSONDecoder().decode([StarredRepo].self, from: data)
        let hasNext = httpResponse?.value(forHTTPHeaderField: "Link")?.contains("rel=\"next\"") ?? false
        return StarredPage(repos: repos, hasNextPage: hasNext)
    }
}
