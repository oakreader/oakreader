import AVFoundation

/// Captures audio from the system microphone using AVAudioEngine.
///
/// Thread safety: `continuation` is accessed from the caller's thread (start/stop)
/// and from the AVAudioEngine tap callback thread, so all access is guarded by `lock`.
public final class MicrophoneCapture: AudioCaptureService, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var tapInstalled = false
    private let lock = NSLock()

    public init() {}

    public func startCapture(sampleRate: Double) throws -> AsyncStream<AVAudioPCMBuffer> {
        stopCapture()

        let inputNode = engine.inputNode

        // NOTE: Voice Processing IO (setVoiceProcessingEnabled) is NOT used here
        // because MicrophoneCapture and SpeakerOutput run on separate AVAudioEngine
        // instances. VP requires both input and output on the same engine to provide
        // an echo-cancellation reference signal. Without it, VP can produce silence
        // or heavily attenuated audio. Echo filtering is handled in VoicePipeline
        // via the interruptMinFrames heuristic instead.

        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw VoiceAgentError.audioCaptureError("Failed to create audio format at \(sampleRate) Hz")
        }

        // Install a converter if the native format differs from the desired format
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
            self.continuation = continuation
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
                        self.currentContinuation()?.yield(convertedBuffer)
                    }
                } else {
                    self.currentContinuation()?.yield(buffer)
                }
            }

            self.lock.lock()
            self.tapInstalled = true
            self.lock.unlock()
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopCapture()
            throw error
        }

        return stream
    }

    public func stopCapture() {
        stopCapture(finishStream: true)
    }

    private func currentContinuation() -> AsyncStream<AVAudioPCMBuffer>.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuation
    }

    private func stopCapture(finishStream: Bool) {
        lock.lock()
        let continuationToFinish = finishStream ? continuation : nil
        continuation = nil
        let shouldRemoveTap = tapInstalled
        tapInstalled = false
        lock.unlock()

        if shouldRemoveTap {
            engine.inputNode.removeTap(onBus: 0)
        }
        if engine.isRunning {
            engine.stop()
        }

        continuationToFinish?.finish()
    }
}
