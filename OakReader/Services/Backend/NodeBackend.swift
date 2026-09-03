import Foundation
import OSLog

/// Owns the Node sidecar process: locate, spawn, handshake, supervise, and
/// multiplex JSONL requests over its stdio. One instance per app.
///
/// Lifecycle: started lazily on first use (or at app launch), restarted with a
/// capped backoff if it dies, torn down on quit. All failures degrade to the
/// in-process OakAI path via `AIBackend` — the sidecar is never load-bearing
/// for correctness in Phase 1.
actor NodeBackend {
    static let shared = NodeBackend()

    private static let log = Logger(subsystem: "com.oakreader.OakReader", category: "NodeBackend")
    private static let maxSpawnAttempts = 3

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var pending: [String: AsyncThrowingStream<String, Error>.Continuation] = [:]
    private var handshakeWaiters: [String: CheckedContinuation<Bool, Never>] = [:]
    private var nextId = 0
    private var spawnAttempts = 0
    private var handshaken = false

    // MARK: - Public

    /// True when the sidecar is running and answered the ping handshake.
    /// Spawns it on first call; retries up to `maxSpawnAttempts` after crashes.
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
        handshaken = await ping(timeout: .seconds(5))
        if handshaken {
            spawnAttempts = 0
            Self.log.info("sidecar handshake OK")
        } else {
            Self.log.error("sidecar handshake failed")
            terminate()
        }
        return handshaken
    }

    /// Stream a completion through the sidecar. Yields text deltas; finishes on
    /// `done`; throws on `error`. Cancelling the consumer sends `abort`.
    func complete(
        model: BackendModelSpec, apiKey: String?, system: String?,
        user: String, maxTokens: Int
    ) -> AsyncThrowingStream<String, Error> {
        nextId += 1
        let id = "c\(nextId)"
        let command = BackendCompleteCommand(
            id: id, model: model, auth: .init(apiKey: apiKey), system: system,
            messages: [.init(role: "user", content: user)], maxTokens: maxTokens
        )
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { termination in
                var aborted = false
                if case .cancelled = termination { aborted = true }
                let wasAborted = aborted
                Task { await self.cleanUp(id: id, aborted: wasAborted) }
            }
            Task { await self.begin(id: id, command: command, continuation: continuation) }
        }
    }

    func shutdown() {
        terminate()
    }

    // MARK: - Request plumbing

    private func begin(
        id: String, command: BackendCompleteCommand,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) {
        pending[id] = continuation
        do {
            try write(command)
        } catch {
            pending.removeValue(forKey: id)
            continuation.finish(throwing: error)
        }
    }

    private func cleanUp(id: String, aborted: Bool) {
        guard pending.removeValue(forKey: id) != nil else { return }
        if aborted {
            try? write(BackendSimpleCommand(id: id, type: "abort"))
        }
    }

    private func ping(timeout: Duration) async -> Bool {
        nextId += 1
        let id = "p\(nextId)"
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            handshakeWaiters[id] = cont
            do {
                try write(BackendSimpleCommand(id: id, type: "ping"))
            } catch {
                handshakeWaiters.removeValue(forKey: id)?.resume(returning: false)
                return
            }
            Task {
                try? await Task.sleep(for: timeout)
                await self.timeOutHandshake(id: id)
            }
        }
    }

    private func timeOutHandshake(id: String) {
        handshakeWaiters.removeValue(forKey: id)?.resume(returning: false)
    }

    private func write(_ command: some Encodable) throws {
        guard let stdinHandle else { throw NodeBackendError.notRunning }
        let encoder = JSONEncoder()
        var data = try encoder.encode(command)
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
        proc.arguments = [script.path]
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
            if let line = String(data: handle.availableData, encoding: .utf8),
               !line.isEmpty {
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
        let waiting = pending
        pending = [:]
        for (_, continuation) in waiting {
            continuation.finish(throwing: NodeBackendError.crashed)
        }
        for (_, waiter) in handshakeWaiters { waiter.resume(returning: false) }
        handshakeWaiters = [:]
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
        switch event.type {
        case "response":
            handshakeWaiters.removeValue(forKey: event.id)?
                .resume(returning: event.success == true && event.protocol == BackendProtocol.version)
        case "delta":
            if let text = event.text { pending[event.id]?.yield(text) }
        case "done":
            pending.removeValue(forKey: event.id)?.finish()
        case "error":
            pending.removeValue(forKey: event.id)?
                .finish(throwing: CompletionStreamError.provider(event.message ?? "backend error"))
        default:
            break
        }
    }

    // MARK: - Discovery

    /// GUI apps don't inherit a shell PATH; probe the usual install locations.
    /// Phase 1.5 replaces this with a Node runtime bundled in the app.
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

    var errorDescription: String? {
        switch self {
        case .nodeNotFound: return "Node.js runtime not found"
        case .scriptNotFound: return "oak-backend.cjs not found in app resources"
        case .notRunning: return "AI backend is not running"
        case .crashed: return "AI backend exited unexpectedly"
        }
    }
}
