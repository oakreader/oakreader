import Foundation

/// Discovers the live model list from an OpenAI-compatible local server (Ollama, LM Studio)
/// by querying its `GET /v1/models` endpoint.
public enum LocalModelDiscovery {
    public enum DiscoveryError: LocalizedError {
        case unreachable(String)
        case badResponse(Int)
        case noModels

        public var errorDescription: String? {
            switch self {
            case .unreachable(let detail): return "Could not reach server: \(detail)"
            case .badResponse(let code): return "Server returned HTTP \(code)"
            case .noModels: return "Server is running but reports no models"
            }
        }
    }

    /// Fetch the model IDs the server currently has loaded/available.
    /// - Parameter apiBase: the OpenAI API base (e.g. `http://localhost:11434/v1`).
    public static func fetchModelIDs(apiBase: URL) async throws -> [String] {
        let url = LocalProviderURL.modelsURL(fromAPIBase: apiBase)
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DiscoveryError.unreachable(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw DiscoveryError.unreachable("invalid response")
        }
        guard http.statusCode == 200 else {
            throw DiscoveryError.badResponse(http.statusCode)
        }

        // OpenAI `/v1/models` shape: { "data": [ { "id": "..." }, ... ] }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let entries = json?["data"] as? [[String: Any]] ?? []
        let ids = entries.compactMap { $0["id"] as? String }
            .filter { !$0.isEmpty }
            .sorted()

        guard !ids.isEmpty else { throw DiscoveryError.noModels }
        return ids
    }
}
