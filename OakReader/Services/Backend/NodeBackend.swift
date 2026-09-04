import Foundation
import OSLog

/// Owns the Node sidecar process: locate, spawn, handshake, supervise, and
/// multiplex JSONL requests over its stdio. One instance per app.
///
/// v2: the sidecar owns providers/credentials/OAuth and the agentic loop, so
/// this actor exposes three shapes:
///  - `request(_:)`  — single response commands (catalog, credentials, config)
///  - `events(for:)` — streaming commands (`complete`, `chat`, `oauth_login`);
///    the stream yields every event for the request id until a terminal one
///  - `send(_:)`     — fire-and-forget replies (`tool_result`, prompt results)
actor NodeBackend {
    static let shared = NodeBackend()

    private static let log = Logger(subsystem: "com.oakreader.OakReader", category: "NodeBackend")
    private static let maxSpawnAttempts = 3

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var streams: [String: AsyncThrowingStream<BackendEvent, Error>.Continuation] = [:]
    private var nextId = 0
    private var spawnAttempts = 0
    private var handshaken = false

    // MARK: - Public

    func makeRequestId(prefix: String = "r") -> String {
        nextId += 1
        return "\(prefix)\(nextId)"
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

    /// Single-response command. Throws `NodeBackendError` when the sidecar is
    /// unavailable or the command fails.
    func request(_ command: BackendCommand) async throws -> BackendEvent {
        guard await ensureRunning() else { throw NodeBackendError.notRunning }
        for try await event in eventStream(for: command) {
            if event.type == "response" || event.type == "error" { return event }
        }
        throw NodeBackendError.crashed
    }

    /// Streaming command: yields every event carrying the command's id.
    /// Terminal events (`done`, `error` for complete/chat; `response` for
    /// oauth_login) finish the stream — an `error` event finishes by throwing.
    /// Cancelling the consumer sends `abort`.
    func events(for command: BackendCommand) async -> AsyncThrowingStream<BackendEvent, Error> {
        guard await ensureRunning() else {
            return AsyncThrowingStream { $0.finish(throwing: NodeBackendError.notRunning) }
        }
        return eventStream(for: command)
    }

    /// Fire-and-forget (tool_result, oauth_prompt_result, abort).
    func send(_ command: BackendCommand) {
        try? write(command)
    }

    func shutdown() {
        terminate()
    }

    // MARK: - Stream plumbing

    private func eventStream(for command: BackendCommand) -> AsyncThrowingStream<BackendEvent, Error> {
        let id = command.id
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    Task { await self.abortRequest(id: id) }
                } else {
                    Task { await self.dropStream(id: id) }
                }
            }
            Task { await self.begin(id: id, command: command, continuation: continuation) }
        }
    }

    private func begin(
        id: String, command: BackendCommand,
        continuation: AsyncThrowingStream<BackendEvent, Error>.Continuation
    ) {
        streams[id] = continuation
        do {
            try write(command)
        } catch {
            streams.removeValue(forKey: id)
            continuation.finish(throwing: error)
        }
    }

    private func abortRequest(id: String) {
        guard streams.removeValue(forKey: id) != nil else { return }
        try? write(BackendCommand(id: id, type: "abort"))
    }

    private func dropStream(id: String) {
        streams.removeValue(forKey: id)
    }

    private func pingHandshake() async -> Bool {
        let id = makeRequestId(prefix: "p")
        do {
            let deadline = Task {
                try await Task.sleep(for: .seconds(5))
                await self.failStream(id: id)
            }
            defer { deadline.cancel() }
            for try await event in eventStream(for: BackendCommand(id: id, type: "ping")) {
                if event.type == "response" {
                    return event.success == true && event.protocol == BackendProtocol.version
                }
            }
        } catch {}
        return false
    }

    private func failStream(id: String) {
        streams.removeValue(forKey: id)?.finish(throwing: NodeBackendError.notRunning)
    }

    private func write(_ command: BackendCommand) throws {
        guard let stdinHandle else { throw NodeBackendError.notRunning }
        var data = try JSONEncoder().encode(command)
        data.append(0x0A)
        try stdinHandle.write(contentsOf: data)
    }

    // MARK: - Process lifecycle

    private func spawn() throws {
        terminate()
        guard let node = Self.findNode() else { throw NodeBackendError.nodeNotFound }
        guard let script = Self.findScript() else { throw NodeBackendError.scriptNotFound }

        let proc = Process()
        proc.executableURL = node
        proc.arguments = [
            script.path,
            "--data-dir", CatalogDatabase.dataDirectory.appendingPathComponent("backend").path,
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
        Self.log.info("sidecar spawned: \(node.path) \(script.path)")
    }

    private func processDied() {
        handshaken = false
        stdinHandle = nil
        process = nil
        let waiting = streams
        streams = [:]
        for (_, continuation) in waiting {
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

    // MARK: - Incoming events

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        // Strict JSONL: split on LF bytes only.
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<newline)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            guard let event = try? JSONDecoder().decode(BackendEvent.self, from: line) else {
                Self.log.error("undecodable event: \(String(data: line, encoding: .utf8) ?? "?")")
                continue
            }
            dispatch(event)
        }
    }

    private func dispatch(_ event: BackendEvent) {
        guard let continuation = streams[event.id] else { return }
        switch event.type {
        case "done", "response":
            continuation.yield(event)
            streams.removeValue(forKey: event.id)
            continuation.finish()
        case "error":
            streams.removeValue(forKey: event.id)
            continuation.finish(throwing: CompletionStreamError.provider(event.message ?? "backend error"))
        default:
            continuation.yield(event)
        }
    }

    // MARK: - Discovery

    /// GUI apps don't inherit a shell PATH; probe the usual install locations.
    /// A bundled Node runtime replaces this in a later phase.
    private static func findNode() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func findScript() -> URL? {
        if let url = Bundle.main.url(forResource: "oak-backend", withExtension: "cjs") {
            return url
        }
        #if DEBUG
        // Debug builds can run straight out of the checkout.
        let source = URL(fileURLWithPath: #filePath)  // …/OakReader/Services/Backend/NodeBackend.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("web/backend/dist/oak-backend.cjs")
        if FileManager.default.fileExists(atPath: source.path) { return source }
        #endif
        return nil
    }
}

enum NodeBackendError: LocalizedError {
    case nodeNotFound
    case scriptNotFound
    case notRunning
    case crashed
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .nodeNotFound:
            return "Node.js 22+ is required for AI features but was not found. Install it from https://nodejs.org or via Homebrew."
        case .scriptNotFound: return "oak-backend.cjs not found in app resources"
        case .notRunning: return "AI backend is not running"
        case .crashed: return "AI backend exited unexpectedly"
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
