import AVFoundation
import Foundation

// MARK: - Configuration

/// Configuration for ElevenLabs WebSocket TTS.
public struct ElevenLabsTTSConfig: Sendable {
    public let apiKey: String
    public let voiceId: String
    public let modelId: String
    public let outputFormat: String
    public let stability: Float
    public let similarityBoost: Float
    public let speed: Float

    public init(
        apiKey: String,
        voiceId: String,
        modelId: String = "eleven_turbo_v2_5",
        outputFormat: String = "pcm_24000",
        stability: Float = 0.5,
        similarityBoost: Float = 0.75,
        speed: Float = 1.0
    ) {
        self.apiKey = apiKey
        self.voiceId = voiceId
        self.modelId = modelId
        self.outputFormat = outputFormat
        self.stability = stability
        self.similarityBoost = similarityBoost
        self.speed = speed
    }
}

// MARK: - Provider

/// Cloud TTS provider using ElevenLabs Multi-Context WebSocket.
///
/// Maintains a persistent WebSocket connection with keepalive. Each
/// `synthesizeStream` call creates a unique context ID, enabling concurrent
/// synthesis requests over the same connection.
public actor ElevenLabsTTSProvider: TTSService {
    private let config: ElevenLabsTTSConfig
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var isConnected = false

    /// Active context continuations keyed by contextId.
    private var activeContexts: [String: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation] = [:]

    private static let maxRetries = 3
    private static let keepaliveIntervalSeconds: UInt64 = 8

    /// Output sample rate parsed from the outputFormat config (e.g. "pcm_24000" → 24000).
    public nonisolated let sampleRate: Double

    public init(config: ElevenLabsTTSConfig) {
        self.config = config
        // Parse sample rate from format string like "pcm_24000"
        if let rateStr = config.outputFormat.split(separator: "_").last,
           let rate = Double(rateStr) {
            self.sampleRate = rate
        } else {
            self.sampleRate = 24000
        }
    }

    // MARK: - TTSService conformance

    public nonisolated func synthesize(
        text: String,
        voice: String?,
        referenceAudioURL: URL?,
        referenceText: String?
    ) async throws -> AVAudioPCMBuffer {
        var buffers: [AVAudioPCMBuffer] = []
        for try await buffer in synthesizeStream(text: text, voice: voice, referenceAudioURL: referenceAudioURL, referenceText: referenceText) {
            buffers.append(buffer)
        }
        guard !buffers.isEmpty else {
            throw VoiceAgentError.ttsFailed("No audio received from ElevenLabs TTS")
        }
        return mergeBuffers(buffers)
    }

    public nonisolated func synthesizeStream(
        text: String,
        voice: String?,
        referenceAudioURL: URL?,
        referenceText: String?
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let contextId = UUID().uuidString
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.handleSynthesizeStream(
                        text: text,
                        contextId: contextId,
                        continuation: continuation
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Internal streaming logic

    private func handleSynthesizeStream(
        text: String,
        contextId: String,
        continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation
    ) async throws {
        try await ensureConnected()

        // Register this context's continuation for the receive loop to route audio to.
        activeContexts[contextId] = continuation

        // Send text for this context
        let textMessage: [String: Any] = [
            "text": text,
            "context_id": contextId,
        ]
        try await sendJSON(textMessage)

        // Flush — signal end of text for this context
        let flushMessage: [String: Any] = [
            "text": "",
            "context_id": contextId,
            "flush": true,
        ]
        try await sendJSON(flushMessage)

        // Close context — signal we won't send more text for this context
        let closeMessage: [String: Any] = [
            "text": "",
            "context_id": contextId,
            "close_context": true,
        ]
        try await sendJSON(closeMessage)

        // The receive loop will yield audio chunks and call finish() on the
        // continuation when it gets isFinal:true for this contextId.
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
                let delay = UInt64(500_000_000) * UInt64(1 << attempt)
                VoiceAgentLog.ttsWarning("TTS WebSocket connect attempt \(attempt + 1) failed: \(error.localizedDescription), retrying...")
                try? await Task.sleep(nanoseconds: delay)
            }
        }
        throw VoiceAgentError.ttsFailed("Failed to connect after \(Self.maxRetries) attempts: \(lastError?.localizedDescription ?? "unknown")")
    }

    private func connect() async throws {
        let queryItems = [
            URLQueryItem(name: "model_id", value: config.modelId),
            URLQueryItem(name: "output_format", value: config.outputFormat),
            URLQueryItem(name: "auto_mode", value: "true"),
        ]
        let urlString = "wss://api.elevenlabs.io/v1/text-to-speech/\(config.voiceId)/multi-stream-input"
        var components = URLComponents(string: urlString)!
        components.queryItems = queryItems
        guard let url = components.url else {
            throw VoiceAgentError.ttsFailed("Invalid TTS WebSocket URL")
        }

        var request = URLRequest(url: url)
        request.setValue(config.apiKey, forHTTPHeaderField: "xi-api-key")

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: request)
        ws.resume()

        self.urlSession = session
        self.webSocket = ws
        self.isConnected = true

        // Send initial message with voice settings
        let initMessage: [String: Any] = [
            "text": " ",
            "voice_settings": [
                "stability": config.stability,
                "similarity_boost": config.similarityBoost,
                "speed": config.speed,
            ],
        ]
        try await sendJSON(initMessage)

        startReceiveLoop()
        startKeepalive()

        VoiceAgentLog.ttsInfo("TTS WebSocket connected for voice \(self.config.voiceId)")
    }

    /// Disconnect and clean up all resources.
    public func disconnect() {
        isConnected = false
        receiveTask?.cancel()
        receiveTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil

        // Finish all active context continuations
        for (_, continuation) in activeContexts {
            continuation.finish()
        }
        activeContexts.removeAll()

        // Send close_socket before disconnecting (best-effort)
        if let ws = webSocket {
            let closeMsg: [String: Any] = ["close_socket": true]
            if let data = try? JSONSerialization.data(withJSONObject: closeMsg),
               let str = String(data: data, encoding: .utf8) {
                ws.send(.string(str)) { _ in }
            }
            ws.cancel(with: .normalClosure, reason: nil)
        }
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        VoiceAgentLog.ttsInfo("TTS WebSocket disconnected")
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
                        VoiceAgentLog.ttsError("TTS receive error: \(error.localizedDescription)")
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // Server responses use camelCase "contextId", client messages use snake_case "context_id"
        let contextId = json["contextId"] as? String

        // Handle audio chunk
        if let audioBase64 = json["audio"] as? String,
           !audioBase64.isEmpty,
           let ctxId = contextId,
           let continuation = activeContexts[ctxId] {
            if let audioData = Data(base64Encoded: audioBase64) {
                if let buffer = pcmDataToBuffer(audioData) {
                    continuation.yield(buffer)
                }
            }
        }

        // Check if this context is finished (FinalOutputMulti message)
        if let isFinal = json["isFinal"] as? Bool, isFinal,
           let ctxId = contextId {
            activeContexts[ctxId]?.finish()
            activeContexts.removeValue(forKey: ctxId)
        }

        // Handle errors
        if let errorMsg = json["error"] as? String {
            VoiceAgentLog.ttsError("TTS server error: \(errorMsg)")
            if let ctxId = contextId {
                activeContexts[ctxId]?.finish(throwing: VoiceAgentError.ttsFailed(errorMsg))
                activeContexts.removeValue(forKey: ctxId)
            }
        }
    }

    private func handleDisconnect() {
        isConnected = false
        keepaliveTask?.cancel()
        keepaliveTask = nil
        // Finish all active contexts with an error
        for (_, continuation) in activeContexts {
            continuation.finish(throwing: VoiceAgentError.ttsFailed("WebSocket disconnected"))
        }
        activeContexts.removeAll()
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.keepaliveIntervalSeconds * 1_000_000_000)
                guard !Task.isCancelled else { break }
                // Send empty text to keep connection alive
                let keepalive: [String: Any] = ["text": ""]
                try? await self.sendJSON(keepalive)
            }
        }
    }

    // MARK: - Helpers

    private func sendJSON(_ dict: [String: Any]) async throws {
        guard let ws = webSocket else {
            throw VoiceAgentError.ttsFailed("WebSocket not connected")
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        let string = String(data: data, encoding: .utf8)!
        try await ws.send(.string(string))
    }

    /// Convert raw Int16 PCM data to AVAudioPCMBuffer (Float32).
    private nonisolated func pcmDataToBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let bytesPerSample = 2 // Int16
        let frameCount = data.count / bytesPerSample
        guard frameCount > 0 else { return nil }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        guard let floatData = buffer.floatChannelData else { return nil }
        let output = floatData[0]

        data.withUnsafeBytes { rawBuffer in
            let int16Ptr = rawBuffer.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                output[i] = Float(int16Ptr[i]) / 32768.0
            }
        }

        return buffer
    }

    /// Merge multiple buffers into a single buffer.
    private nonisolated func mergeBuffers(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer {
        let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard let format = buffers.first?.format,
              let merged = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames))
        else {
            return buffers[0]
        }
        merged.frameLength = AVAudioFrameCount(totalFrames)

        guard let outData = merged.floatChannelData else { return buffers[0] }
        var offset = 0
        for buf in buffers {
            guard let inData = buf.floatChannelData else { continue }
            let count = Int(buf.frameLength)
            memcpy(outData[0].advanced(by: offset), inData[0], count * MemoryLayout<Float>.size)
            offset += count
        }
        return merged
    }
}
