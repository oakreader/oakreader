import AVFoundation
import CoreAudio
import Synchronization

/// Plays audio buffers through the system speakers using AVAudioEngine.
public final class SpeakerOutput: AudioPlaybackService, @unchecked Sendable {
    private struct PlaybackState {
        var isPlaying = false
        var pendingCompletion: CheckedContinuation<Void, Never>?
    }

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let playbackState = Mutex(PlaybackState())
    private let deviceUID: String?

    public var isPlaying: Bool {
        playbackState.withLock { $0.isPlaying }
    }

    public init(deviceUID: String? = nil) {
        self.deviceUID = deviceUID
        engine.attach(playerNode)
    }

    public func play(buffers: AsyncThrowingStream<AVAudioPCMBuffer, Error>) async throws {
        playbackState.withLock {
            $0.isPlaying = true
            $0.pendingCompletion = nil
        }

        defer {
            cleanup(resumePendingCompletion: false)
        }

        var format: AVAudioFormat?
        var started = false

        for try await buffer in buffers {
            try Task.checkCancellation()

            // Lazily connect and start the engine on first buffer
            if !started {
                format = buffer.format
                engine.connect(playerNode, to: engine.mainMixerNode, format: format)
                engine.prepare()
                if let uid = deviceUID, !uid.isEmpty,
                   let deviceID = AudioDeviceManager.resolveDeviceID(uid: uid) {
                    try engine.outputNode.auAudioUnit.setDeviceID(deviceID)
                }
                try engine.start()
                playerNode.play()
                started = true
            }

            try await scheduleAndWaitForPlayback(buffer)
        }

        cleanup()
    }

    public func stop() {
        cleanup()
    }

    private func scheduleAndWaitForPlayback(_ buffer: AVAudioPCMBuffer) async throws {
        try Task.checkCancellation()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let shouldResumeImmediately = playbackState.withLock { state in
                    guard state.isPlaying else { return true }
                    state.pendingCompletion = continuation
                    playerNode.scheduleBuffer(buffer) { [weak self] in
                        self?.resumePendingCompletion()
                    }
                    return false
                }

                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.stop()
        }

        try Task.checkCancellation()
    }

    private func resumePendingCompletion() {
        let continuation = playbackState.withLock { state in
            let continuation = state.pendingCompletion
            state.pendingCompletion = nil
            return continuation
        }
        continuation?.resume()
    }

    private func cleanup(resumePendingCompletion: Bool = true) {
        let continuation = playbackState.withLock { state in
            state.isPlaying = false
            let continuation = state.pendingCompletion
            if resumePendingCompletion {
                state.pendingCompletion = nil
            }
            return resumePendingCompletion ? continuation : nil
        }

        playerNode.stop()
        if engine.isRunning {
            engine.stop()
        }
        engine.disconnectNodeOutput(playerNode)
        continuation?.resume()
    }
}
