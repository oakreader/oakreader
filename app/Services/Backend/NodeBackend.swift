import Foundation
import OSLog

/// Owns the sidecar process and speaks JSON-RPC 2.0 to it over stdio.
///
/// The peer is symmetric: both sides send requests, and a reverse call
/// (`tool/execute`, `oauth/prompt`) is an ordinary request that happens to
/// arrive rather than depart. That is why there is one `pending` map instead
/// of the three bespoke correlation tables the previous protocol needed, and
/// why cancellation is one notification rather than a prefix scan over
/// string-concatenated keys.
///
/// Three call shapes, matching the spec rather than our old ad-hoc scheme:
///  - `call(_:params:as:)`   — request, awaits a typed result or throws RPCErrorObject
///  - `stream(_:params:as:)` — request whose progress notifications are yielded
///                             until the response finishes the stream
///  - `notify(_:params:)`    — notification, no reply expected
/// Inbound requests are served by handlers registered with `setHandler`.
actor NodeBackend {
    static let shared = NodeBackend()

    private static let log = Logger(subsystem: "com.oakreader.OakReader", category: "NodeBackend")
    private static let maxSpawnAttempts = 3
    private static let writeQueue = DispatchQueue(label: "com.oakreader.NodeBackend.stdin")
    /// Ceiling for a plain request. Generous: model-catalog refreshes and OAuth
    /// token exchanges both hit the network. Streaming calls are exempt — a chat
    /// turn may idle while the user decides on a tool confirmation.
    private static let requestTimeout = Duration.seconds(30)

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var nextId = 0
    private var spawnAttempts = 0
    private var handshaken = false

    /// Requests we sent, awaiting their response. Both plain and streaming
    /// calls live here; a streaming one also has an entry in `progress`.
    private var pending: [String: CheckedContinuation<JSONFragment?, Error>] = [:]
    /// Streaming calls, by request id, fed by notifications carrying that token.
    private var progress: [String: AsyncThrowingStream<RPCStreamEvent, Error>.Continuation] = [:]
    /// Handlers for requests the sidecar sends us.
    private var handlers: [String: (JSONFragment?) async -> Result<JSONFragment?, RPCErrorObject>] = [:]

    // MARK: - Public

    private func nextRequestId() -> String {
        nextId += 1
        return "c\(nextId)"
    }

    /// Serve inbound requests for one method. Registered once at startup.
    func setHandler(
        _ method: String,
        _ handler: @escaping (JSONFragment?) async -> Result<JSONFragment?, RPCErrorObject>
    ) {
        handlers[method] = handler
    }

    /// True when the sidecar is running and answered the ping handshake.
    func ensureRunning() async -> Bool {
        if handshaken, process?.isRunning == true { return true }
        guard spawnAttempts < Self.maxSpawnAttempts else { return false }
        spawnAttempts += 1
        do {
            try spawn()
        } catch {
            Self.log.error("sidecar spawn failed: \(error.localizedDescription)")
            return false
        }
        handshaken = await pingHandshake()
        if handshaken {
            spawnAttempts = 0
            Self.log.info("sidecar handshake OK")
        } else {
            Self.log.error("sidecar handshake failed")
            terminate()
        }
        return handshaken
    }

    /// A request that returns once. Throws `RPCErrorObject` when the sidecar
    /// answers with an error — the code is what lets callers branch.
    func call<P: Encodable, R: Decodable>(
        _ method: String, params: P, as: R.Type
    ) async throws -> R {
        guard await ensureRunning() else { throw NodeBackendError.notRunning }
        let id = nextRequestId()
        let deadline = Task {
            try await Task.sleep(for: Self.requestTimeout)
            await self.failPending(id: id, with: NodeBackendError.timedOut)
        }
        defer { deadline.cancel() }
        let result = try await send(id: id, method: method, params: params)
        return try RPCCoding.decode(R.self, from: result)
    }

    /// A request whose only outcome is success or an error.
    func call<P: Encodable>(_ method: String, params: P) async throws {
        _ = try await call(method, params: params, as: RPCEmpty.self)
    }

    /// A request whose progress notifications are delivered as they arrive.
    /// The stream finishes when the response lands and throws when it is an
    /// error. Cancelling the consumer sends `$/cancelRequest`.
    func stream<P: Encodable>(
        _ method: String, params: P
    ) async -> AsyncThrowingStream<RPCStreamEvent, Error> {
        guard await ensureRunning() else {
            return AsyncThrowingStream { $0.finish(throwing: NodeBackendError.notRunning) }
        }
        let id = nextRequestId()
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    Task { await self.cancel(id: id) }
                }
            }
            Task {
                await self.attachProgress(id: id, continuation: continuation)
                do {
                    _ = try await self.send(id: id, method: method, params: params)
                    await self.finishProgress(id: id, error: nil)
                } catch {
                    await self.finishProgress(id: id, error: error)
                }
            }
        }
    }

    /// Answer a reverse call that arrived on a stream.
    func respond<R: Encodable>(to id: String, with result: R) {
        guard let fragment = try? RPCCoding.fragment(result) else {
            respondError(to: id, code: RPC.ErrorCode.internalError, message: "could not encode result")
            return
        }
        try? write(.response(id: id, result: fragment))
    }

    func respondError(to id: String, code: Int, message: String) {
        try? write(.failure(id: id, code: code, message: message))
    }

    /// Fire-and-forget. No id, so the peer must not reply.
    func notify<P: Encodable>(_ method: String, params: P) async {
        guard let fragment = try? RPCCoding.fragment(params) else { return }
        try? write(.notification(method: method, params: fragment))
    }

    func shutdown() { terminate() }

    // MARK: - Request plumbing

    private func send<P: Encodable>(id: String, method: String, params: P) async throws -> JSONFragment? {
        let fragment = try RPCCoding.fragment(params)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try write(.request(id: id, method: method, params: fragment))
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func attachProgress(
        id: String, continuation: AsyncThrowingStream<RPCStreamEvent, Error>.Continuation
    ) {
        progress[id] = continuation
    }

    private func finishProgress(id: String, error: Error?) {
        guard let continuation = progress.removeValue(forKey: id) else { return }
        if let error { continuation.finish(throwing: error) } else { continuation.finish() }
    }

    private func failPending(id: String, with error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    /// One notification replaces the previous protocol's per-request abort
    /// command plus the prefix scan that cleaned up its children.
    private func cancel(id: String) async {
        guard pending[id] != nil else { return }
        await notify(RPC.Method.cancelRequest, params: RPC.CancelRequestParams(id: id))
    }

    private func pingHandshake() async -> Bool {
        do {
            let id = nextRequestId()
            let deadline = Task {
                try await Task.sleep(for: .seconds(5))
                await self.failPending(id: id, with: NodeBackendError.timedOut)
            }
            defer { deadline.cancel() }
            let raw = try await send(id: id, method: RPC.Method.ping, params: RPC.PingParams())
            let result = try RPCCoding.decode(RPC.PingResult.self, from: raw)
            if result.protocol != RPC.version {
                Self.log.error("protocol mismatch: sidecar \(result.protocol), shell \(RPC.version)")
                return false
            }
            Self.log.info("sidecar \(result.backend)")
            return true
        } catch {
            return false
        }
    }

    private func write(_ envelope: RPCEnvelope) throws {
        guard let stdinHandle else { throw NodeBackendError.notRunning }
        var data = try JSONEncoder().encode(envelope)
        data.append(0x0A)
        let handle = stdinHandle
        // Off the actor: a pipe blocks its writer once the reader is ~64 KB
        // behind, and one frame can exceed that on its own. Blocking here would
        // stall every other call into this actor, including the response the
        // sidecar is waiting for before it drains its input. The queue is
        // serial, so frames still arrive in order.
        Self.writeQueue.async {
            do { try handle.write(contentsOf: data) }
            catch { Self.log.error("stdin write failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Incoming

    private func dispatch(_ envelope: RPCEnvelope) {
        switch envelope.kind {
        case .response(let id):
            pending.removeValue(forKey: id)?.resume(returning: envelope.result)

        case .failure(let id, let error):
            pending.removeValue(forKey: id)?.resume(throwing: error)

        case .notification(let method):
            // Progress is addressed by the token naming the request it belongs to.
            guard case .object(let fields)? = envelope.params,
                  case .string(let token)? = fields["token"],
                  let continuation = progress[token] else { return }
            continuation.yield(.notification(method: method, params: envelope.params))

        case .request(let id, let method):
            // Scoped reverse call: if the params name a request of ours that is
            // still streaming, its consumer owns the answer.
            if case .object(let fields)? = envelope.params,
               case .string(let token)? = fields["token"],
               let continuation = progress[token] {
                continuation.yield(.request(id: id, method: method, params: envelope.params))
                return
            }
            guard let handler = handlers[method] else {
                try? write(.failure(id: id, code: RPC.ErrorCode.methodNotFound,
                                    message: "no handler for \(method)"))
                return
            }
            Task {
                switch await handler(envelope.params) {
                case .success(let result): try? await self.write(.response(id: id, result: result))
                case .failure(let error):
                    try? await self.write(.failure(id: id, code: error.code, message: error.message))
                }
            }

        case .malformed:
            Self.log.error("malformed envelope")
        }
    }

    // MARK: - Process lifecycle

    private func spawn() throws {
        terminate()
        guard let binary = Self.findBinary() else { throw NodeBackendError.scriptNotFound }

        let proc = Process()
        proc.executableURL = binary
        proc.arguments = [
            // Provider config and credentials.
            "--data-dir", CatalogDatabase.dataDirectory.appendingPathComponent("backend").path,
            // The user's library. A separate flag because these are separate
            // things: one is the sidecar's own state, the other is the
            // documents, and phase 1 made the sidecar the only process that
            // opens the second one.
            "--library", CatalogDatabase.dataDirectory.appendingPathComponent("library.sqlite").path,
        ]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            Task { await self.receive(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            if let line = String(data: handle.availableData, encoding: .utf8), !line.isEmpty {
                Self.log.debug("\(line.trimmingCharacters(in: .newlines))")
            }
        }
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { await self.processDied() }
        }

        try proc.run()
        process = proc
        stdinHandle = stdin.fileHandleForWriting
        stdoutBuffer = Data()
        Self.log.info("sidecar spawned: \(binary.path)")
    }

    private func processDied() {
        handshaken = false
        stdinHandle = nil
        process = nil
        let waitingRequests = pending
        pending = [:]
        for (_, continuation) in waitingRequests {
            continuation.resume(throwing: NodeBackendError.crashed)
        }
        let waitingStreams = progress
        progress = [:]
        for (_, continuation) in waitingStreams {
            continuation.finish(throwing: NodeBackendError.crashed)
        }
        Self.log.error("sidecar exited")
    }

    private func terminate() {
        guard let process else { return }
        process.terminationHandler = nil
        try? stdinHandle?.close()
        if process.isRunning { process.terminate() }
        self.process = nil
        stdinHandle = nil
        handshaken = false
    }

    // MARK: - Framing

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        // Strict JSONL: split on LF bytes only, never on U+2028/U+2029.
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newline)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            guard let envelope = try? JSONDecoder().decode(RPCEnvelope.self, from: line) else {
                Self.log.error("undecodable envelope: \(String(data: line, encoding: .utf8) ?? "?")")
                continue
            }
            dispatch(envelope)
        }
    }

    // MARK: - Discovery

    /// The sidecar is a self-contained executable produced by `bun build
    /// --compile` (backend/scripts/build-binary.sh), so the Bun runtime is
    /// inside it. Nothing is probed on the user's machine: there is no `node`
    /// lookup and no minimum runtime version. This is what Dia ships too — its
    /// agent-server, handler and claude binaries are all compiled the same way.
    private static func findBinary() -> URL? {
        if let url = Bundle.main.url(forResource: "oak-backend", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        #if DEBUG
        // Debug builds can run straight out of the checkout.
        let source = URL(fileURLWithPath: #filePath)  // …/app/Services/Backend/NodeBackend.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("backend/dist/oak-backend")
        if FileManager.default.isExecutableFile(atPath: source.path) { return source }
        #endif
        return nil
    }
}

enum NodeBackendError: LocalizedError {
    case scriptNotFound
    case notRunning
    case crashed
    case timedOut
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptNotFound: return "The AI backend executable is missing from the app bundle."
        case .notRunning: return "AI backend is not running"
        case .crashed: return "AI backend exited unexpectedly"
        case .timedOut: return "AI backend stopped responding"
        case .commandFailed(let message): return message
        }
    }
}

enum CompletionStreamError: LocalizedError {
    case provider(String)

    var errorDescription: String? {
        switch self {
        case .provider(let message): return message
        }
    }
}
