import AVFoundation
import Foundation

// MARK: - Configuration

/// Configuration for ElevenLabs Scribe v2 Realtime STT.
public struct ElevenLabsSTTConfig: Sendable {
    public let apiKey: String
    public let modelId: String
    public let languageCode: String
    public let baseURL: String

    public init(
        apiKey: String,
        modelId: String = "scribe_v2_realtime",
        languageCode: String = "en",
        baseURL: String = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
    ) {
        self.apiKey = apiKey
        self.modelId = modelId
        self.languageCode = languageCode
        self.baseURL = baseURL
    }
}

// MARK: - Provider

/// Cloud STT provider using ElevenLabs Scribe v2 Realtime WebSocket.
///
/// Connects lazily on first use, stays connected across turns via keepalive,
/// and supports manual commit strategy for precise utterance boundaries.
public actor ElevenLabsSTTProvider: STTService {
    private let config: ElevenLabsSTTConfig
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var isConnected = false
    private var sessionStarted = false

    /// In-flight transcription task — tracked so we can cancel orphans.
    private var inflightTask: Task<Void, Never>?

    // Per-request state — only one transcription active at a time.
    private var resultContinuation: AsyncThrowingStream<TranscriptionResult, Error>.Continuation?
    private var commitWaiter: CheckedContinuation<Void, Error>?
    private var sessionWaiter: CheckedContinuation<Void, Error>?

    private static let maxRetries = 3
    private static let keepaliveIntervalSeconds: UInt64 = 8
    private static let sessionStartedTimeoutNs: UInt64 = 10_000_000_000 // 10s
    private static let commitTimeoutNs: UInt64 = 15_000_000_000 // 15s
    // 320 bytes = 160 Int16 samples = 10ms of 16kHz mono PCM
    private static let silentChunkSize = 320

    public init(config: ElevenLabsSTTConfig) {
        self.config = config
    }

    // MARK: - STTService conformance

    public nonisolated func transcribe(audio: AVAudioPCMBuffer) async throws -> TranscriptionResult {
        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            continuation.yield(audio)
            continuation.finish()
        }
        var lastResult: TranscriptionResult?
        for try await result in transcribeStream(audioStream: stream) {
            lastResult = result
        }
        guard let final = lastResult else {
            throw VoiceAgentError.sttFailed("No transcription result received")
        }
        return final
    }

    public nonisolated func transcribeStream(
        audioStream: AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncThrowingStream<TranscriptionResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.handleTranscribeStream(audioStream: audioStream, continuation: continuation)
                } catch {
                    if !Task.isCancelled {
                        continuation.finish(throwing: error)
                    } else {
                        continuation.finish()
                    }
                }
            }
            // When the consumer stops iterating (e.g. pipeline cancels),
            // cancel our internal task so it doesn't become an orphan.
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Internal streaming logic

    private func handleTranscribeStream(
        audioStream: AsyncStream<AVAudioPCMBuffer>,
        continuation: AsyncThrowingStream<TranscriptionResult, Error>.Continuation
    ) async throws {
        // Cancel any previous in-flight transcription to avoid state corruption.
        cancelInflight()

        try await ensureConnected()
        self.resultContinuation = continuation

        // Wait for session_started with timeout
        if !sessionStarted {
            try await waitForSessionStarted()
        }

        try Task.checkCancellation()

        // Send audio chunks as they arrive
        for await buffer in audioStream {
            try Task.checkCancellation()
            let base64 = pcmBufferToBase64(buffer)
            let message: [String: Any] = [
                "message_type": "input_audio_chunk",
                "audio_base_64": base64,
                "commit": false,
            ]
            try await sendJSON(message)
        }

        try Task.checkCancellation()

        // All audio consumed — commit the utterance
        let commitMessage: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": "",
            "commit": true,
        ]
        try await sendJSON(commitMessage)

        // Wait for the committed_transcript response with timeout.
        try await waitForCommit()

        self.resultContinuation = nil
        continuation.finish()
    }

    /// Cancel any previous in-flight transcription and clean up its state.
    private func cancelInflight() {
        inflightTask?.cancel()
        inflightTask = nil
        // Clean up stale per-request state from a previous (possibly orphaned) call
        resultContinuation?.finish()
        resultContinuation = nil
        if let waiter = commitWaiter {
            waiter.resume(throwing: CancellationError())
            commitWaiter = nil
        }
        if let waiter = sessionWaiter {
            waiter.resume(throwing: CancellationError())
            sessionWaiter = nil
        }
    }

    // MARK: - Connection management

    private func ensureConnected() async throws {
        if isConnected { return }
        try await connectWithRetry()
    }

    private func connectWithRetry() async throws {
        var lastError: Error?
        for attempt in 0..<Self.maxRetries {
            do {
                try await connect()
                return
            } catch {
                lastError = error
                let delay = UInt64(500_000_000) * UInt64(1 << attempt) // 500ms, 1s, 2s
                VoiceAgentLog.sttWarning("STT connect attempt \(attempt + 1) failed: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        throw VoiceAgentError.sttFailed("Failed to connect after \(Self.maxRetries) attempts: \(lastError?.localizedDescription ?? "unknown")")
    }

    private func connect() async throws {
        // Clean up any previous connection
        cleanupConnection()

        let queryItems = [
            URLQueryItem(name: "model_id", value: config.modelId),
            URLQueryItem(name: "language_code", value: config.languageCode),
            URLQueryItem(name: "commit_strategy", value: "manual"),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
        ]
        var components = URLComponents(string: config.baseURL)!
        components.queryItems = queryItems
        guard let url = components.url else {
            throw VoiceAgentError.sttFailed("Invalid STT WebSocket URL")
        }

        var request = URLRequest(url: url)
        request.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: request)
        ws.resume()

        self.urlSession = session
        self.webSocket = ws
        self.isConnected = true
        self.sessionStarted = false

        startReceiveLoop()
        startKeepalive()

        VoiceAgentLog.sttInfo("STT WebSocket connecting to \(self.config.baseURL)")
    }

    private func cleanupConnection() {
        receiveTask?.cancel()
        receiveTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        isConnected = false
        sessionStarted = false
    }

    /// Disconnect and clean up all resources.
    public func disconnect() {
        cancelInflight()
        cleanupConnection()
        VoiceAgentLog.sttInfo("STT WebSocket disconnected")
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        receiveTask?.cancel()
        receiveTask = Task {
            while !Task.isCancelled {
                do {
                    guard let ws = self.webSocket else { break }
                    let message = try await ws.receive()
                    self.handleMessage(message)
                } catch {
                    if !Task.isCancelled {
                        VoiceAgentLog.sttError("STT receive error: \(error.localizedDescription)")
                        self.handleDisconnect()
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messageType = json["message_type"] as? String
        else { return }

        switch messageType {
        case "session_started":
            VoiceAgentLog.sttInfo("STT session started")
            sessionStarted = true
            sessionWaiter?.resume()
            sessionWaiter = nil

        case "partial_transcript":
            if let transcript = json["text"] as? String, !transcript.isEmpty {
                resultContinuation?.yield(TranscriptionResult(
                    text: transcript,
                    isFinal: false
                ))
            }

        case "committed_transcript", "committed_transcript_with_timestamps":
            if let transcript = json["text"] as? String, !transcript.isEmpty {
                resultContinuation?.yield(TranscriptionResult(
                    text: transcript,
                    isFinal: true
                ))
            }
            // Resume the commit waiter so handleTranscribeStream can finish
            commitWaiter?.resume()
            commitWaiter = nil

        case "error", "auth_error", "quota_exceeded", "rate_limited",
             "commit_throttled", "input_error", "chunk_size_exceeded",
             "transcriber_error", "session_time_limit_exceeded",
             "resource_exhausted", "queue_overflow":
            let errorMsg = json["error"] as? String ?? "ElevenLabs STT error: \(messageType)"
            VoiceAgentLog.sttError("STT server error [\(messageType)]: \(errorMsg)")
            let sttError = VoiceAgentError.sttFailed(errorMsg)
            resultContinuation?.finish(throwing: sttError)
            resultContinuation = nil
            commitWaiter?.resume(throwing: sttError)
            commitWaiter = nil
            sessionWaiter?.resume(throwing: sttError)
            sessionWaiter = nil

        default:
            break
        }
    }

    private func handleDisconnect() {
        let disconnectError = VoiceAgentError.sttFailed("WebSocket disconnected")
        resultContinuation?.finish(throwing: disconnectError)
        resultContinuation = nil
        commitWaiter?.resume(throwing: disconnectError)
        commitWaiter = nil
        sessionWaiter?.resume(throwing: disconnectError)
        sessionWaiter = nil
        isConnected = false
        sessionStarted = false
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.keepaliveIntervalSeconds * 1_000_000_000)
                guard !Task.isCancelled else { break }
                let silentData = Data(count: Self.silentChunkSize)
                let base64 = silentData.base64EncodedString()
                let message: [String: Any] = [
                    "message_type": "input_audio_chunk",
                    "audio_base_64": base64,
                    "commit": false,
                ]
                try? await self.sendJSON(message)
            }
        }
    }

    // MARK: - Helpers

    private func sendJSON(_ dict: [String: Any]) async throws {
        guard let ws = webSocket else {
            throw VoiceAgentError.sttFailed("WebSocket not connected")
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        let string = String(data: data, encoding: .utf8)!
        try await ws.send(.string(string))
    }

    /// Convert AVAudioPCMBuffer to base64-encoded Int16 PCM data.
    private nonisolated func pcmBufferToBase64(_ buffer: AVAudioPCMBuffer) -> String {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return "" }

        var int16Data = Data(capacity: frameCount * 2)

        if let floatData = buffer.floatChannelData {
            let samples = floatData[0]
            for i in 0..<frameCount {
                let clamped = max(-1.0, min(1.0, samples[i]))
                var sample = Int16(clamped * 32767)
                withUnsafeBytes(of: &sample) { int16Data.append(contentsOf: $0) }
            }
        } else if let int16ChannelData = buffer.int16ChannelData {
            let samples = int16ChannelData[0]
            int16Data.append(UnsafeBufferPointer(start: samples, count: frameCount))
        }

        return int16Data.base64EncodedString()
    }

    /// Wait for session_started with a timeout.
    private func waitForSessionStarted() async throws {
        if sessionStarted { return }

        // Start a timeout task that will resume the waiter with an error
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: Self.sessionStartedTimeoutNs)
            // If we get here, the timeout fired before session_started arrived
            if let waiter = self.sessionWaiter {
                self.sessionWaiter = nil
                waiter.resume(throwing: VoiceAgentError.sttFailed("Timed out waiting for session_started"))
            }
        }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.sessionWaiter = cont
            }
            timeoutTask.cancel()
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    /// Wait for committed_transcript with a timeout.
    private func waitForCommit() async throws {
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: Self.commitTimeoutNs)
            if let waiter = self.commitWaiter {
                self.commitWaiter = nil
                waiter.resume(throwing: VoiceAgentError.sttFailed("Timed out waiting for committed_transcript"))
            }
        }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.commitWaiter = cont
            }
            timeoutTask.cancel()
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }
}
