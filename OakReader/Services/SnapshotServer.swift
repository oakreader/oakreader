import Foundation
import Network

/// Lightweight HTTP server on `127.0.0.1:23119` that receives POST `/snapshot`
/// payloads from the OakReader Chrome extension and routes them to `ImportService`.
final class SnapshotServer {
    private var listener: NWListener?
    private let importService: ImportService
    private let port: UInt16 = 23119
    private let maxPayload = 50 * 1024 * 1024 // 50 MB

    init(importService: ImportService) {
        self.importService = importService
    }

    // MARK: - Start / Stop

    func start() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            NSLog("[SnapshotServer] Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                NSLog("[SnapshotServer] Listening on 127.0.0.1:\(self.port)")
            case .failed(let error):
                NSLog("[SnapshotServer] Listener failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        NSLog("[SnapshotServer] Stopped")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        // Read up to maxPayload + some headroom for headers
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxPayload + 65536) { [weak self] data, _, _, error in
            guard let self, let data else {
                if let error {
                    NSLog("[SnapshotServer] Receive error: \(error)")
                }
                connection.cancel()
                return
            }

            self.processHTTPRequest(data: data, connection: connection)
        }
    }

    // MARK: - HTTP Parsing

    private func processHTTPRequest(data: Data, connection: NWConnection) {
        guard let raw = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, status: 400, body: #"{"status":"error","message":"Invalid encoding"}"#)
            return
        }

        // Split headers and body
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let headerSection = parts[0]
        let bodyString = parts.count > 1 ? parts.dropFirst().joined(separator: "\r\n\r\n") : ""
        let headerLines = headerSection.components(separatedBy: "\r\n")

        guard let requestLine = headerLines.first else {
            sendResponse(connection: connection, status: 400, body: #"{"status":"error","message":"No request line"}"#)
            return
        }

        let tokens = requestLine.split(separator: " ", maxSplits: 2)
        guard tokens.count >= 2 else {
            sendResponse(connection: connection, status: 400, body: #"{"status":"error","message":"Malformed request"}"#)
            return
        }

        let method = String(tokens[0])
        let path = String(tokens[1])

        // OPTIONS (CORS preflight)
        if method == "OPTIONS" {
            sendResponse(connection: connection, status: 204, body: "")
            return
        }

        // Only accept POST /snapshot
        guard method == "POST", path == "/snapshot" else {
            sendResponse(connection: connection, status: 404, body: #"{"status":"error","message":"Not found"}"#)
            return
        }

        guard !bodyString.isEmpty, let bodyData = bodyString.data(using: .utf8) else {
            sendResponse(connection: connection, status: 400, body: #"{"status":"error","message":"Empty body"}"#)
            return
        }

        do {
            let payload = try JSONDecoder().decode(SnapshotPayload.self, from: bodyData)
            handlePayload(payload) { result in
                switch result {
                case .success:
                    self.sendResponse(connection: connection, status: 200, body: #"{"status":"ok"}"#)
                case .failure(let error):
                    let msg = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
                    self.sendResponse(connection: connection, status: 500, body: #"{"status":"error","message":"\#(msg)"}"#)
                }
            }
        } catch {
            NSLog("[SnapshotServer] JSON decode error: \(error)")
            sendResponse(connection: connection, status: 400, body: #"{"status":"error","message":"Invalid JSON"}"#)
        }
    }

    // MARK: - Payload Dispatch

    private func handlePayload(_ payload: SnapshotPayload, completion: @escaping (Result<Void, Error>) -> Void) {
        switch payload.type {
        case "html":
            handleHTMLSnapshot(payload, completion: completion)
        case "youtube":
            handleYouTube(payload, completion: completion)
        case "podcast":
            handlePodcast(payload, completion: completion)
        default:
            completion(.failure(OakReaderError.serverError("Unknown type: \(payload.type)")))
        }
    }

    private func handleHTMLSnapshot(_ payload: SnapshotPayload, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let html = payload.html else {
            completion(.failure(OakReaderError.serverError("Missing html field")))
            return
        }

        // Write HTML to a temp file
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = sanitizeFileName(payload.title ?? "snapshot") + ".html"
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString + "_" + fileName)

        do {
            try html.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            completion(.failure(error))
            return
        }

        let originalURL = URL(string: payload.url)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let item = self.importService.importWebSnapshot(from: tempURL, originalPageURL: originalURL, title: payload.title)
            try? FileManager.default.removeItem(at: tempURL)
            if item != nil {
                completion(.success(()))
            } else {
                completion(.failure(OakReaderError.serverError("Import failed")))
            }
        }
    }

    private func handleYouTube(_ payload: SnapshotPayload, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let sourceURL = URL(string: payload.url) else {
            completion(.failure(OakReaderError.serverError("Invalid URL")))
            return
        }

        let metadata = MediaMetadata(
            title: payload.title ?? "Untitled Video",
            author: payload.author ?? "",
            sourceURL: sourceURL,
            duration: payload.duration,
            thumbnailURL: payload.thumbnailURL.flatMap { URL(string: $0) },
            publishedAt: nil,
            description: payload.description,
            feedURL: nil,
            episodeTitle: nil
        )

        // Download thumbnail if available
        downloadData(from: payload.thumbnailURL) { thumbnailData in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let item = self.importService.importYouTubeVideo(
                    title: payload.title ?? "Untitled Video",
                    author: payload.author ?? "",
                    sourceURL: sourceURL,
                    duration: payload.duration,
                    thumbnailData: thumbnailData,
                    transcript: payload.transcript,
                    metadata: metadata
                )
                if item != nil {
                    completion(.success(()))
                } else {
                    completion(.failure(OakReaderError.serverError("YouTube import failed")))
                }
            }
        }
    }

    private func handlePodcast(_ payload: SnapshotPayload, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let sourceURL = URL(string: payload.url) else {
            completion(.failure(OakReaderError.serverError("Invalid URL")))
            return
        }

        let metadata = MediaMetadata(
            title: payload.episodeTitle ?? payload.title ?? "Untitled Episode",
            author: payload.author ?? "",
            sourceURL: sourceURL,
            duration: payload.duration,
            thumbnailURL: payload.thumbnailURL.flatMap { URL(string: $0) },
            publishedAt: nil,
            description: payload.description,
            feedURL: payload.feedURL.flatMap { URL(string: $0) },
            episodeTitle: payload.episodeTitle
        )

        // Download thumbnail if available
        downloadData(from: payload.thumbnailURL) { thumbnailData in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let item = self.importService.importPodcastEpisode(
                    title: payload.episodeTitle ?? payload.title ?? "Untitled Episode",
                    author: payload.author ?? "",
                    sourceURL: sourceURL,
                    duration: payload.duration,
                    thumbnailData: thumbnailData,
                    transcript: payload.transcript,
                    audioData: nil,
                    metadata: metadata
                )
                if item != nil {
                    completion(.success(()))
                } else {
                    completion(.failure(OakReaderError.serverError("Podcast import failed")))
                }
            }
        }
    }

    // MARK: - HTTP Response

    private func sendResponse(connection: NWConnection, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }

        let bodyData = body.data(using: .utf8) ?? Data()
        var headers = "HTTP/1.1 \(status) \(statusText)\r\n"
        headers += "Content-Type: application/json\r\n"
        headers += "Content-Length: \(bodyData.count)\r\n"
        headers += "Access-Control-Allow-Origin: *\r\n"
        headers += "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
        headers += "Access-Control-Allow-Headers: Content-Type\r\n"
        headers += "Connection: close\r\n"
        headers += "\r\n"

        var responseData = headers.data(using: .utf8)!
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Helpers

    private func sanitizeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalid).joined(separator: "_")
            .prefix(100)
            .trimmingCharacters(in: .whitespaces)
    }

    private func downloadData(from urlString: String?, completion: @escaping (Data?) -> Void) {
        guard let urlString, let url = URL(string: urlString) else {
            completion(nil)
            return
        }

        URLSession.shared.dataTask(with: url) { data, _, _ in
            completion(data)
        }.resume()
    }
}

// MARK: - Payload

struct SnapshotPayload: Codable {
    let type: String            // "html" | "youtube" | "podcast"
    let url: String
    let title: String?
    let author: String?
    let html: String?           // html only
    let videoId: String?        // youtube only
    let duration: Int?
    let thumbnailURL: String?
    let transcript: String?
    let episodeTitle: String?   // podcast only
    let feedURL: String?
    let audioURL: String?
    let description: String?
}
