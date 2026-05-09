import AVFoundation
import CoreAudio

/// Unified audio I/O engine that shares a single `AVAudioEngine` for both
/// microphone capture and speaker playback. This enables Apple's Voice
/// Processing IO (hardware echo cancellation) — the engine uses the playback
/// output as a reference signal to subtract echo from the microphone input,
/// preventing the agent's own TTS audio from being detected as user speech.
///
/// Thread safety: mutable state is guarded by `lock`. The engine, input tap,
/// and player node all live on the same `AVAudioEngine` instance.
public final class VoiceIOEngine: AudioCaptureService, AudioPlaybackService, @unchecked Sendable {

    // MARK: - Shared engine

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let lock = NSLock()

    // MARK: - Capture state

    private var captureContinuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var tapInstalled = false

    // MARK: - Playback state

    private struct PlaybackState {
        var isPlaying = false
        var pendingCompletion: CheckedContinuation<Void, Never>?
    }

    private var _playback = PlaybackState()

    public var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _playback.isPlaying
    }

    private let inputDeviceUID: String?
    private let outputDeviceUID: String?

    // MARK: - Init

    public init(inputDeviceUID: String? = nil, outputDeviceUID: String? = nil) {
        self.inputDeviceUID = inputDeviceUID
        self.outputDeviceUID = outputDeviceUID
        engine.attach(playerNode)
    }

    // MARK: - AudioCaptureService

    public func startCapture(sampleRate: Double) throws -> AsyncStream<AVAudioPCMBuffer> {
        stopCapture()

        let inputNode = engine.inputNode

        // Set custom input device before enabling VP (VP queries the device).
        if let uid = inputDeviceUID, !uid.isEmpty,
           let deviceID = AudioDeviceManager.resolveDeviceID(uid: uid) {
            try inputNode.auAudioUnit.setDeviceID(deviceID)
        }

        // Enable Voice Processing IO — the shared engine carries both input
        // and output so VP can use the playback signal as an echo-cancellation
        // reference. On macOS, VP at the HAL level also references the system
        // output device directly. The playerNode is connected lazily in play().
        try inputNode.setVoiceProcessingEnabled(true)

        // Read native format AFTER enabling VP (it may change the format).
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw VoiceAgentError.audioCaptureError("Failed to create audio format at \(sampleRate) Hz")
        }

        let needsConversion = nativeFormat.sampleRate != sampleRate || nativeFormat.channelCount != 1
        let converter: AVAudioConverter?
        if needsConversion {
            guard let conv = AVAudioConverter(from: nativeFormat, to: desiredFormat) else {
                throw VoiceAgentError.audioCaptureError("Failed to create audio converter")
            }
            converter = conv
        } else {
            converter = nil
        }

        let stream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self.lock.lock()
            self.captureContinuation = continuation
            self.lock.unlock()

            continuation.onTermination = { @Sendable _ in
                self.stopCapture(finishStream: false)
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat) { [weak self] buffer, _ in
                guard let self else { return }
                if let converter {
                    let frameCount = AVAudioFrameCount(
                        Double(buffer.frameLength) * sampleRate / nativeFormat.sampleRate
                    )
                    guard let convertedBuffer = AVAudioPCMBuffer(
                        pcmFormat: desiredFormat,
                        frameCapacity: frameCount
                    ) else { return }

                    var error: NSError?
                    var allConsumed = false
                    converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                        if allConsumed {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        allConsumed = true
                        outStatus.pointee = .haveData
                        return buffer
                    }

                    if error == nil, convertedBuffer.frameLength > 0 {
                        self.currentCaptureContinuation()?.yield(convertedBuffer)
                    }
                } else {
                    self.currentCaptureContinuation()?.yield(buffer)
                }
            }

            self.lock.lock()
            self.tapInstalled = true
            self.lock.unlock()
        }

        engine.prepare()

        // Set custom output device before starting the engine.
        if let uid = outputDeviceUID, !uid.isEmpty,
           let deviceID = AudioDeviceManager.resolveDeviceID(uid: uid) {
            try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
        }

        try engine.start()

        return stream
    }

    public func stopCapture() {
        stopCapture(finishStream: true)
    }

    // MARK: - AudioPlaybackService

    public func play(buffers: AsyncThrowingStream<AVAudioPCMBuffer, Error>) async throws {
        beginPlayback()

        defer { cleanupPlayback(resumePendingCompletion: false) }

        var reconnectedFormat: AVAudioFormat?

        for try await buffer in buffers {
            try Task.checkCancellation()

            // Reconnect player node with the TTS buffer format if it differs
            // from the initial connection. This ensures proper sample rate matching.
            if reconnectedFormat == nil || reconnectedFormat != buffer.format {
                reconnectedFormat = buffer.format
                reconnectPlayerNode(format: buffer.format)
            }

            try await scheduleAndWaitForPlayback(buffer)
        }

        cleanupPlayback()
    }

    /// Synchronous helper — safe to call from any context.
    private func beginPlayback() {
        lock.lock()
        _playback.isPlaying = true
        _playback.pendingCompletion = nil
        lock.unlock()
    }

    /// Synchronous helper — reconnects player node with a new format.
    private func reconnectPlayerNode(format: AVAudioFormat) {
        lock.lock()
        playerNode.stop()
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        playerNode.play()
        lock.unlock()
    }

    public func stop() {
        cleanupPlayback()
    }

    // MARK: - Internal helpers

    private func currentCaptureContinuation() -> AsyncStream<AVAudioPCMBuffer>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return captureContinuation
    }

    private func stopCapture(finishStream: Bool) {
        lock.lock()
        let continuationToFinish = finishStream ? captureContinuation : nil
        captureContinuation = nil
        let shouldRemoveTap = tapInstalled
        tapInstalled = false
        lock.unlock()

        if shouldRemoveTap {
            engine.inputNode.removeTap(onBus: 0)
        }

        // Stop the engine only when capture ends — this tears down everything.
        lock.lock()
        playerNode.stop()
        _playback.isPlaying = false
        let pendingCompletion = _playback.pendingCompletion
        _playback.pendingCompletion = nil
        lock.unlock()

        engine.disconnectNodeOutput(playerNode)
        if engine.isRunning {
            engine.stop()
        }

        pendingCompletion?.resume()
        continuationToFinish?.finish()
    }

    private func scheduleAndWaitForPlayback(_ buffer: AVAudioPCMBuffer) async throws {
        try Task.checkCancellation()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                guard _playback.isPlaying else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                _playback.pendingCompletion = continuation
                playerNode.scheduleBuffer(buffer) { [weak self] in
                    self?.resumePendingCompletion()
                }
                lock.unlock()
            }
        } onCancel: {
            self.stop()
        }

        try Task.checkCancellation()
    }

    private func resumePendingCompletion() {
        lock.lock()
        let continuation = _playback.pendingCompletion
        _playback.pendingCompletion = nil
        lock.unlock()
        continuation?.resume()
    }

    private func cleanupPlayback(resumePendingCompletion doResume: Bool = true) {
        lock.lock()
        _playback.isPlaying = false
        let continuation = _playback.pendingCompletion
        if doResume {
            _playback.pendingCompletion = nil
        }
        lock.unlock()

        playerNode.stop()
        // Do NOT stop the engine or disconnect — capture is still active.
        if doResume {
            continuation?.resume()
        }
    }
}
