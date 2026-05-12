import AVFoundation
import ScreenCaptureKit

/// Captures system audio via ScreenCaptureKit (records both sides of a call).
final class SystemAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// Start capturing system audio at the given sample rate.
    /// Returns an async stream of audio buffers.
    func startCapture(sampleRate: Double = 44100) async throws -> AsyncStream<AVAudioPCMBuffer> {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw SystemAudioError.noDisplay
        }

        // Audio-only capture: exclude all windows and apps, capture display audio
        let filter = SCContentFilter(
            display: display,
            excludingApplications: content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            },
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1
        // Minimize video capture overhead (audio-only use case)
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        self.stream = stream

        let asyncStream = AsyncStream<AVAudioPCMBuffer> { continuation in
            self.continuation = continuation
        }

        try await stream.startCapture()
        return asyncStream
    }

    /// Stop system audio capture.
    func stopCapture() {
        Task {
            try? await stream?.stopCapture()
            stream = nil
            continuation?.finish()
            continuation = nil
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }
        continuation?.yield(pcmBuffer)
    }

    enum SystemAudioError: LocalizedError {
        case noDisplay

        var errorDescription: String? {
            switch self {
            case .noDisplay: "No display found for screen capture"
            }
        }
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

private extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = formatDescription else { return nil }
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        guard let asbd else { return nil }

        guard let avFormat = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(self)
        guard frameCount > 0 else { return nil }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        ) == noErr else {
            return nil
        }

        return pcmBuffer
    }
}
