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
            Log.error(Log.server, "Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Log.info(Log.server, "Listening on 127.0.0.1:\(self.port)")
            case .failed(let error):
                Log.error(Log.server, "Listener failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        Log.info(Log.server, "Stopped")
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        accumulateRequest(connection: connection, buffer: Data())
    }

    /// Accumulate TCP segments until the full HTTP request (headers + body) has arrived.
    private func accumulateRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: maxPayload + 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }

            guard let data else {
                if let error { Log.error(Log.server, "Receive error: \(error)") }
                connection.cancel()
                return
            }

            var accumulated = buffer
            accumulated.append(data)

            // Check if we have the full request by parsing Content-Length
            if let raw = String(data: accumulated, encoding: .utf8),
               let headerEnd = raw.range(of: "\r\n\r\n") {
                let headerSection = String(raw[raw.startIndex..<headerEnd.lowerBound])
                let bodyStart = accumulated.count - raw[headerEnd.upperBound...].utf8.count
                let bodyReceived = accumulated.count - bodyStart

                // Parse Content-Length from headers
                let contentLength = headerSection
                    .components(separatedBy: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") }
                    ?? 0

                if bodyReceived >= contentLength || isComplete {
                    self.processHTTPRequest(data: accumulated, connection: connection)
                    return
                }
            }

            if isComplete {
                // Connection closed before we could parse — process what we have
                self.processHTTPRequest(data: accumulated, connection: connection)
            } else if accumulated.count > self.maxPayload + 65536 {
                self.sendResponse(connection: connection, status: 413, body: #"{"status":"error","message":"Payload too large"}"#)
            } else {
                // Need more data — keep reading
                self.accumulateRequest(connection: connection, buffer: accumulated)
            }
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

        // GET /collections
        if method == "GET", path == "/collections" {
            handleGetCollections(connection: connection)
            return
        }

        // GET /tags
        if method == "GET", path == "/tags" {
            handleGetTags(connection: connection)
            return
        }

        // POST /snapshot
        if method == "POST", path == "/snapshot" {
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
                Log.error(Log.server, "JSON decode error: \(error)")
                sendResponse(connection: connection, status: 400, body: #"{"status":"error","message":"Invalid JSON"}"#)
            }
            return
        }

        sendResponse(connection: connection, status: 404, body: #"{"status":"error","message":"Not found"}"#)
    }

    // MARK: - GET /collections

    private func handleGetCollections(connection: NWConnection) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let collections = self.importService.store.collections

            // Flatten collections with parent info for the extension
            var result: [[String: Any]] = []
            func flatten(_ colls: [PDFCollection], parentId: String?) {
                for c in colls {
                    var entry: [String: Any] = [
                        "id": c.id.uuidString,
                        "name": c.name,
                        "icon": c.icon,
                    ]
                    if let pid = parentId {
                        entry["parentId"] = pid
                    }
                    result.append(entry)
                    flatten(c.subcollections, parentId: c.id.uuidString)
                }
            }
            flatten(collections.filter { $0.parentId == nil }, parentId: nil)

            // Serialize
            if let jsonData = try? JSONSerialization.data(withJSONObject: result),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: jsonString)
            } else {
                self.sendResponse(connection: connection, status: 200, body: "[]")
            }
        }
    }

    // MARK: - GET /tags

    private func handleGetTags(connection: NWConnection) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let store = self.importService.store
            let pairs = store.tagOptionsWithCounts()
            let tree = TagNode.buildHierarchy(from: pairs)

            func serialize(_ nodes: [TagNode]) -> [[String: Any]] {
                nodes.map { node in
                    var entry: [String: Any] = [
                        "id": node.id.uuidString,
                        "name": node.name,
                        "fullPath": node.fullPath,
                        "count": node.count,
                    ]
                    if !node.children.isEmpty {
                        entry["children"] = serialize(node.children)
                    }
                    if node.option != nil {
                        entry["isTag"] = true
                    }
                    return entry
                }
            }

            let result = serialize(tree)
            if let jsonData = try? JSONSerialization.data(withJSONObject: result),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                self.sendResponse(connection: connection, status: 200, body: jsonString)
            } else {
                self.sendResponse(connection: connection, status: 200, body: "[]")
            }
        }
    }

    // MARK: - Payload Dispatch

    private func handlePayload(_ payload: SnapshotPayload, completion: @escaping (Result<Void, Error>) -> Void) {
        switch payload.type {
        case "html":
            handleHTMLSnapshot(payload, completion: completion)
        case "embed":
            handleEmbed(payload, completion: completion)
        case "pdf":
            handlePDFSnapshot(payload, completion: completion)
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
            if let item {
                // Save extracted markdown alongside snapshot HTML
                if let markdown = payload.markdown, !markdown.isEmpty {
                    let mdURL = item.fileURL.deletingLastPathComponent()
                        .appendingPathComponent("content.md")
                    try? markdown.write(to: mdURL, atomically: true, encoding: .utf8)
                }
                self.assignToCollection(item: item, collectionId: payload.collectionId)
                self.assignTags(item: item, tagOptionIds: payload.tagOptionIds)
                self.createAndAssignNewTags(item: item, newTags: payload.newTags)
                completion(.success(()))
            } else {
                completion(.failure(OakReaderError.serverError("Import failed")))
            }
        }
    }

    private func handleEmbed(_ payload: SnapshotPayload, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let sourceURL = URL(string: payload.url) else {
            completion(.failure(OakReaderError.serverError("Invalid URL")))
            return
        }

        let resolvedEmbedType = payload.embedType ?? Self.detectEmbedType(from: payload.url)

        let metadata = MediaMetadata(
            title: payload.title ?? "Untitled",
            author: payload.author ?? "",
            sourceURL: sourceURL,
            duration: payload.duration,
            thumbnailURL: payload.thumbnailURL.flatMap { URL(string: $0) },
            publishedAt: nil,
            description: payload.description,
            embedType: resolvedEmbedType
        )

        // Download thumbnail if available
        downloadData(from: payload.thumbnailURL) { thumbnailData in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let item = self.importService.importEmbed(
                    title: payload.title ?? "Untitled",
                    author: payload.author ?? "",
                    sourceURL: sourceURL,
                    duration: payload.duration,
                    thumbnailData: thumbnailData,
                    transcript: payload.transcript,
                    metadata: metadata,
                    embedType: resolvedEmbedType
                )
                if let item {
                    self.assignToCollection(item: item, collectionId: payload.collectionId)
                    self.assignTags(item: item, tagOptionIds: payload.tagOptionIds)
                    self.createAndAssignNewTags(item: item, newTags: payload.newTags)
                    completion(.success(()))
                } else {
                    completion(.failure(OakReaderError.serverError("Embed import failed")))
                }
            }
        }
    }

    /// Infer embed type from URL when not explicitly provided by the extension.
    private static func detectEmbedType(from urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return "youtube" }
        if host.contains("youtube.com") || host.contains("youtu.be") { return "youtube" }
        if host.contains("x.com") || host.contains("twitter.com") { return "twitter" }
        return "link"
    }

    // MARK: - PDF Snapshot

    private func handlePDFSnapshot(_ payload: SnapshotPayload, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let pdfURL = URL(string: payload.url) else {
            completion(.failure(OakReaderError.serverError("Invalid PDF URL")))
            return
        }

        // Build request with forwarded cookies for authenticated downloads
        var request = URLRequest(url: pdfURL)
        if let cookies = payload.cookies, !cookies.isEmpty {
            request.setValue(cookies, forHTTPHeaderField: "Cookie")
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                completion(.failure(OakReaderError.serverError("PDF download failed: \(error.localizedDescription)")))
                return
            }

            guard let data, !data.isEmpty else {
                completion(.failure(OakReaderError.serverError("PDF download returned empty data")))
                return
            }

            // Verify we got a PDF (check magic bytes %PDF)
            let prefix = data.prefix(5)
            guard prefix.count >= 4, String(data: Data(prefix.prefix(4)), encoding: .ascii) == "%PDF" else {
                completion(.failure(OakReaderError.serverError("Downloaded content is not a valid PDF")))
                return
            }

            // Derive filename from URL or title
            let filename: String
            if let urlFilename = pdfURL.lastPathComponent.removingPercentEncoding,
               urlFilename.lowercased().hasSuffix(".pdf") {
                filename = urlFilename
            } else {
                filename = self.sanitizeFileName(payload.title ?? "download") + ".pdf"
            }

            // Write to temp file
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "_" + filename)
            do {
                try data.write(to: tempURL)
            } catch {
                completion(.failure(error))
                return
            }

            DispatchQueue.main.async {
                let item = self.importService.importPDF(from: tempURL)
                try? FileManager.default.removeItem(at: tempURL)
                if let item {
                    self.assignToCollection(item: item, collectionId: payload.collectionId)
                    self.assignTags(item: item, tagOptionIds: payload.tagOptionIds)
                    self.createAndAssignNewTags(item: item, newTags: payload.newTags)
                    completion(.success(()))
                } else {
                    completion(.failure(OakReaderError.serverError("PDF import failed")))
                }
            }
        }.resume()
    }

    // MARK: - Collection Assignment

    /// Assigns an imported item to a collection if a collectionId was provided.
    /// Must be called on the main thread.
    private func assignToCollection(item: LibraryItem, collectionId: String?) {
        guard let collectionId else { return }
        let store = importService.store
        guard let collection = store.collections.first(where: { $0.id.uuidString == collectionId }) else {
            Log.error(Log.server, "Collection not found: \(collectionId)")
            return
        }
        store.addItem(item, to: collection)
    }

    /// Assigns tags to an imported item.
    /// Must be called on the main thread.
    private func assignTags(item: LibraryItem, tagOptionIds: [String]?) {
        guard let tagOptionIds, !tagOptionIds.isEmpty else { return }
        let store = importService.store
        guard let tagsProp = store.tagsProperty else {
            Log.error(Log.server, "Tags property not found")
            return
        }
        for optionIdStr in tagOptionIds {
            guard let option = tagsProp.options.first(where: { $0.id.uuidString == optionIdStr }) else {
                Log.error(Log.server, "Tag option not found: \(optionIdStr)")
                continue
            }
            store.setItemSelectValue(item: item, property: tagsProp, option: option)
        }
    }

    /// Creates new tag options and assigns them to an imported item.
    /// Must be called on the main thread.
    private func createAndAssignNewTags(item: LibraryItem, newTags: [String]?) {
        guard let newTags, !newTags.isEmpty else { return }
        let store = importService.store
        guard let tagsProp = store.tagsProperty else {
            Log.error(Log.server, "Tags property not found")
            return
        }

        // Color palette for auto-created tags (matching the app's tag editor)
        let palette = ["2EA8E5", "A28AE5", "5FB236", "FF8C19", "E57373",
                        "4DB6AC", "FFB74D", "7986CB", "F48FB1", "AED581"]

        for tagName in newTags {
            let trimmed = tagName.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Check if a tag with this name already exists
            if let existing = tagsProp.options.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                store.setItemSelectValue(item: item, property: tagsProp, option: existing)
                continue
            }

            // Pick a color from palette based on name hash for consistency
            let colorIndex = abs(trimmed.hashValue) % palette.count
            let colorHex = palette[colorIndex]

            if let newOption = store.addPropertyOption(propertyId: tagsProp.id, name: trimmed, colorHex: colorHex) {
                store.setItemSelectValue(item: item, property: tagsProp, option: newOption)
            } else {
                Log.error(Log.server, "Failed to create tag: \(trimmed)")
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
        headers += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
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
    let type: String            // "html" | "embed" | "pdf"
    let url: String
    let title: String?
    let author: String?
    let html: String?           // html only
    let markdown: String?       // html only — Readability + Turndown extracted text
    let videoId: String?        // embed (YouTube) only
    let duration: Int?
    let thumbnailURL: String?
    let transcript: String?
    let description: String?
    let cookies: String?        // pdf only — forwarded cookies for authenticated downloads
    let collectionId: String?   // optional — target collection, nil = unsorted
    let tagOptionIds: [String]? // optional — tag option UUIDs to assign
    let newTags: [String]?      // optional — tag names to create and assign
    let embedType: String?      // "youtube" | "twitter" | "link", nil → inferred from URL
}
