import Foundation
import Network

/// Lightweight HTTP server on `127.0.0.1:23119` that bridges the OakReader browser
/// extension and the app: it receives clip payloads on `POST /clip` (routed to
/// `ImportService`) and serves library data back via `GET /collections`, `/tags`,
/// and `/selected-collection`.
final class OakServer {
    private var listener: NWListener?
    private let importService: ImportService
    private let port: UInt16 = 23119
    private let maxPayload = 100 * 1024 * 1024 // 100 MB

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

            // Check if we have the full request by finding \r\n\r\n at byte level
            if let headerEndOffset = self.findHeaderEnd(in: accumulated) {
                let headerData = accumulated[accumulated.startIndex..<(accumulated.startIndex + headerEndOffset)]
                let bodyStart = headerEndOffset + 4 // skip \r\n\r\n
                let bodyReceived = accumulated.count - bodyStart

                // Parse Content-Length from header bytes
                var contentLength = 0
                if let headerString = String(data: headerData, encoding: .utf8) {
                    contentLength = headerString
                        .components(separatedBy: "\r\n")
                        .first(where: { $0.lowercased().hasPrefix("content-length:") })
                        .flatMap { Int($0.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") }
                        ?? 0
                }

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

    /// Find the byte sequence `\r\n\r\n` in Data, returning the range.
    private func findHeaderEnd(in data: Data) -> Int? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        guard data.count >= 4 else { return nil }
        for i in 0...(data.count - 4) {
            if data[data.startIndex + i] == separator[0] &&
               data[data.startIndex + i + 1] == separator[1] &&
               data[data.startIndex + i + 2] == separator[2] &&
               data[data.startIndex + i + 3] == separator[3] {
                return i
            }
        }
        return nil
    }

    private func processHTTPRequest(data: Data, connection: NWConnection) {
        // Find header/body boundary at the byte level (avoid String conversion of entire payload)
        guard let headerEndOffset = findHeaderEnd(in: data) else {
            sendResponse(connection: connection, status: 400, body: #"{"status":"error","message":"Malformed request"}"#)
            return
        }

        let headerData = data[data.startIndex..<(data.startIndex + headerEndOffset)]
        let bodyData = data[(data.startIndex + headerEndOffset + 4)...] // skip \r\n\r\n

        guard let headerString = String(data: headerData, encoding: .utf8) else {
            sendResponse(connection: connection, status: 400, body: #"{"status":"error","message":"Invalid header encoding"}"#)
            return
        }

        let headerLines = headerString.components(separatedBy: "\r\n")

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

        // GET /selected-collection
        if method == "GET", path == "/selected-collection" {
            handleGetSelectedCollection(connection: connection)
            return
        }

        // POST /clip
        if method == "POST", path == "/clip" {
            guard !bodyData.isEmpty else {
                sendResponse(connection: connection, status: 400, body: #"{"status":"error","message":"Empty body"}"#)
                return
            }

            do {
                let payload = try JSONDecoder().decode(ClipPayload.self, from: Data(bodyData))
                handleClip(payload) { result in
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

            // Serialize as a tree with children (matching the tags endpoint pattern)
            func serialize(_ colls: [PDFCollection]) -> [[String: Any]] {
                colls.map { c in
                    var entry: [String: Any] = [
                        "id": c.id.uuidString,
                        "name": c.name,
                        "icon": c.icon,
                    ]
                    if !c.subcollections.isEmpty {
                        entry["children"] = serialize(c.subcollections)
                    }
                    return entry
                }
            }

            let result = serialize(collections.filter { $0.parentId == nil })

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
                    if let option = node.option {
                        entry["isTag"] = true
                        entry["colorHex"] = option.colorHex
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

    // MARK: - GET /selected-collection

    private func handleGetSelectedCollection(connection: NWConnection) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let store = self.importService.store
            if let id = store.selectedCollectionId {
                let json = #"{"id":"\#(id.uuidString)"}"#
                self.sendResponse(connection: connection, status: 200, body: json)
            } else {
                self.sendResponse(connection: connection, status: 200, body: #"{"id":null}"#)
            }
        }
    }

    // MARK: - Payload Dispatch

    private func handleClip(_ payload: ClipPayload, completion: @escaping (Result<Void, Error>) -> Void) {
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

    private func handleHTMLSnapshot(_ payload: ClipPayload, completion: @escaping (Result<Void, Error>) -> Void) {
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
            let item = self.importService.importHTML(
                from: tempURL,
                originalPageURL: originalURL,
                title: payload.title,
                contentMarkdown: payload.markdown
            )
            try? FileManager.default.removeItem(at: tempURL)
            if let item {
                self.assignToCollection(item: item, collectionId: payload.collectionId)
                self.assignTags(item: item, tagOptionIds: payload.tagOptionIds)
                self.createAndAssignNewTags(item: item, newTags: payload.newTags)
                // Process scholarly bibliographic metadata if present
                if let biblio = payload.biblio {
                    self.processScholarlyMetadata(biblio, forItem: item)
                }
                completion(.success(()))
            } else {
                completion(.failure(OakReaderError.serverError("Import failed")))
            }
        }
    }

    // MARK: - Scholarly Metadata Processing

    /// Processes bibliographic metadata from the browser extension's scholarly translator.
    /// If a DOI is present, attempts CrossRef lookup for full CSL; otherwise builds CSL from provided fields.
    private func processScholarlyMetadata(_ biblio: BiblioPayload, forItem item: LibraryItem) {
        let itemId = item.id.uuidString

        Task {
            var cslItem: CSLItem?

            // If DOI present, try CrossRef for complete metadata
            if let doi = biblio.doi, !doi.isEmpty {
                do {
                    cslItem = try await CrossRefService.fetchMetadata(doi: doi)
                } catch {
                    Log.error(Log.server, "CrossRef lookup failed for DOI \(doi): \(error)")
                }
            }

            // If CrossRef failed or no DOI, build CSL from biblio fields
            if cslItem == nil {
                var csl = CSLItem(type: biblio.cslType ?? "webpage")
                csl.title = item.title
                csl.DOI = biblio.doi
                csl.ISSN = biblio.issn
                csl.ISBN = biblio.isbn
                csl.containerTitle = biblio.journal
                csl.volume = biblio.volume
                csl.issue = biblio.issue
                csl.page = biblio.pages
                csl.publisher = biblio.publisher
                csl.URL = item.sourceURL?.absoluteString

                if let year = biblio.year {
                    csl.issued = CSLDate(dateParts: [[year]])
                }

                if let authors = biblio.authors, !authors.isEmpty {
                    csl.author = authors.map { CSLName(family: $0.family, given: $0.given) }
                }

                cslItem = csl
            }

            if let csl = cslItem {
                do {
                    try self.importService.referenceService.saveMetadata(csl, forItemId: itemId)
                    await MainActor.run {
                        self.importService.store.invalidate()
                    }
                } catch {
                    Log.error(Log.server, "Failed to save scholarly metadata: \(error)")
                }
            }
        }
    }

    private func handleEmbed(_ payload: ClipPayload, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let sourceURL = URL(string: payload.url) else {
            completion(.failure(OakReaderError.serverError("Invalid URL")))
            return
        }

        // The extension always tags embeds explicitly ("youtube" | "link");
        // a missing tag falls back to a generic link rather than guessing from the URL.
        let resolvedEmbedType = payload.embedType ?? "link"

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
                let item = self.importService.importEmbed(.init(
                    title: payload.title ?? "Untitled",
                    author: payload.author ?? "",
                    sourceURL: sourceURL,
                    duration: payload.duration,
                    thumbnailData: thumbnailData,
                    transcript: payload.transcript,
                    metadata: metadata,
                    embedType: resolvedEmbedType,
                    contentMarkdown: payload.markdown
                ))
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


    // MARK: - PDF Snapshot

    private func handlePDFSnapshot(_ payload: ClipPayload, completion: @escaping (Result<Void, Error>) -> Void) {
        Log.info(Log.server, "handlePDFSnapshot: url=\(payload.url), pdfData=\(payload.pdfData != nil ? "\(payload.pdfData!.count) chars" : "nil"), cookies=\(payload.cookies != nil ? "yes" : "nil")")

        // Inline PDF data from Page.printToPDF (base64-encoded PDF bytes)
        if let pdfDataString = payload.pdfData, !pdfDataString.isEmpty {
            handleInlinePDF(payload, pdfBase64: pdfDataString, completion: completion)
            return
        }

        Log.info(Log.server, "No pdfData — falling back to URL download: \(payload.url)")

        // URL-based PDF: download the PDF file directly
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

    /// Import a base64-encoded PDF received directly from the extension's Page.printToPDF.
    private func handleInlinePDF(_ payload: ClipPayload, pdfBase64: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let pdfData = Data(base64Encoded: pdfBase64) else {
            completion(.failure(OakReaderError.serverError("Invalid base64 PDF data")))
            return
        }

        let filename = sanitizeFileName(payload.title ?? "snapshot") + ".pdf"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_" + filename)

        do {
            try pdfData.write(to: tempURL)
        } catch {
            completion(.failure(error))
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let item = self.importService.importPDF(from: tempURL)
            try? FileManager.default.removeItem(at: tempURL)
            if let item {
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
                completion(.failure(OakReaderError.serverError("PDF import failed")))
            }
        }
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

struct ClipPayload: Codable {
    let type: String            // "html" | "embed" | "pdf"
    let url: String
    let title: String?
    let author: String?
    let html: String?           // html only
    let markdown: String?       // html & pdf — Defuddle/Turndown extracted text
    let videoId: String?        // embed (YouTube) only
    let duration: Int?
    let thumbnailURL: String?
    let transcript: String?
    let description: String?
    let cookies: String?        // pdf only — forwarded cookies for authenticated downloads
    let pdfData: String?         // pdf only — base64-encoded PDF from Page.printToPDF
    let collectionId: String?   // optional — target collection, nil = unsorted
    let tagOptionIds: [String]? // optional — tag option UUIDs to assign
    let newTags: [String]?      // optional — tag names to create and assign
    let embedType: String?      // "youtube" | "link" (embed clips only), nil → treated as link
    let biblio: BiblioPayload?  // scholarly metadata from browser extension
}

// MARK: - Bibliographic Metadata

struct BiblioPayload: Codable {
    let doi: String?
    let issn: String?
    let isbn: String?
    let journal: String?
    let volume: String?
    let issue: String?
    let pages: String?
    let publisher: String?
    let year: Int?
    let authors: [BiblioAuthor]?
    let cslType: String?
}

struct BiblioAuthor: Codable {
    let given: String?
    let family: String?
}
