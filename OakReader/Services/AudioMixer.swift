import AVFoundation

/// Mixes microphone and system audio streams into a single mono Float32 output.
/// Uses time-aligned 250ms window mixing with auto-gain normalization.
final class AudioMixer: @unchecked Sendable {
    private let sampleRate: Double
    private let windowSize: Int  // samples per 250ms window
    private var micBuffer: [Float] = []
    private var sysBuffer: [Float] = []
    private let lock = NSLock()

    /// Gain applied to system audio. Auto-adjusted so system RMS is ~90% of mic RMS.
    private var systemGain: Float = 2.0
    private static let minGain: Float = 1.0
    private static let maxGain: Float = 4.0
    private static let targetRatio: Float = 0.9

    init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
        self.windowSize = Int(sampleRate * 0.25)
    }

    /// Maximum buffered samples per source before dropping oldest data.
    /// At 44100 Hz this is ~10 seconds — far more than the 250ms window needs.
    private static let maxBufferSamples = 44100 * 10

    /// Mix two async audio streams into a single output stream.
    func mix(
        micStream: AsyncStream<AVAudioPCMBuffer>,
        systemStream: AsyncStream<AVAudioPCMBuffer>
    ) -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream { continuation in
            let mixTask = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                await withTaskGroup(of: Void.self) { group in
                    // Collect mic audio in background
                    group.addTask {
                        for await buffer in micStream {
                            guard !Task.isCancelled else { break }
                            self.appendMic(buffer)
                        }
                    }

                    // Collect system audio in background
                    group.addTask {
                        for await buffer in systemStream {
                            guard !Task.isCancelled else { break }
                            self.appendSystem(buffer)
                        }
                    }

                    // Periodically produce mixed output windows
                    group.addTask {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 62_500_000) // 62.5ms
                            if let mixed = self.drainWindow() {
                                continuation.yield(mixed)
                            }
                        }
                    }

                    // When any task finishes (streams end or cancellation),
                    // cancel the rest so the group completes.
                    // Wait for one completion, then cancel siblings.
                    _ = await group.next()
                    group.cancelAll()
                }

                // Drain remaining
                if let mixed = self.drainRemaining() {
                    continuation.yield(mixed)
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                mixTask.cancel()
            }
        }
    }

    // MARK: - Buffer Management

    private func appendMic(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: data[0], count: count))
        lock.lock()
        micBuffer.append(contentsOf: samples)
        // Drop oldest samples if buffer grows beyond cap
        if micBuffer.count > Self.maxBufferSamples {
            micBuffer.removeFirst(micBuffer.count - Self.maxBufferSamples)
        }
        lock.unlock()
    }

    private func appendSystem(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let count = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: data[0], count: count))
        lock.lock()
        sysBuffer.append(contentsOf: samples)
        if sysBuffer.count > Self.maxBufferSamples {
            sysBuffer.removeFirst(sysBuffer.count - Self.maxBufferSamples)
        }
        lock.unlock()
    }

    /// Drain one full window of mixed audio if enough data is available.
    private func drainWindow() -> AVAudioPCMBuffer? {
        lock.lock()
        guard micBuffer.count >= windowSize else {
            lock.unlock()
            return nil
        }

        let micSamples = Array(micBuffer.prefix(windowSize))
        micBuffer.removeFirst(windowSize)

        let sysSamples: [Float]
        if sysBuffer.count >= windowSize {
            sysSamples = Array(sysBuffer.prefix(windowSize))
            sysBuffer.removeFirst(windowSize)
        } else {
            // If system audio is behind, use zeros
            sysSamples = [Float](repeating: 0, count: windowSize)
        }
        lock.unlock()

        updateGain(micSamples: micSamples, sysSamples: sysSamples)
        return mixSamples(mic: micSamples, system: sysSamples)
    }

    /// Drain any remaining samples as a final mixed buffer.
    private func drainRemaining() -> AVAudioPCMBuffer? {
        lock.lock()
        let count = max(micBuffer.count, sysBuffer.count)
        guard count > 0 else {
            lock.unlock()
            return nil
        }

        let micSamples = micBuffer
        let sysSamples = sysBuffer
        micBuffer.removeAll()
        sysBuffer.removeAll()
        lock.unlock()

        let padded = max(micSamples.count, sysSamples.count)
        let mic = micSamples + [Float](repeating: 0, count: padded - micSamples.count)
        let sys = sysSamples + [Float](repeating: 0, count: padded - sysSamples.count)

        return mixSamples(mic: mic, system: sys)
    }

    // MARK: - Mixing

    private func mixSamples(mic: [Float], system: [Float]) -> AVAudioPCMBuffer? {
        let count = mic.count
        guard count > 0 else { return nil }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(count)

        guard let output = buffer.floatChannelData?[0] else { return nil }

        for i in 0..<count {
            let mixed = mic[i] + system[i] * systemGain
            output[i] = max(-1.0, min(1.0, mixed))
        }

        return buffer
    }

    private func updateGain(micSamples: [Float], sysSamples: [Float]) {
        let micRMS = rms(micSamples)
        let sysRMS = rms(sysSamples)

        guard sysRMS > 0.001 && micRMS > 0.001 else { return }

        let targetRMS = micRMS * Self.targetRatio
        let desiredGain = targetRMS / sysRMS
        let clampedGain = max(Self.minGain, min(Self.maxGain, desiredGain))

        // Smooth transition
        systemGain = systemGain * 0.8 + clampedGain * 0.2
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumSquares / Float(samples.count))
    }
}
