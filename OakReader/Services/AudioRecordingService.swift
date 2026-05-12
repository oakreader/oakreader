import AVFoundation
import CoreMedia
import OakVoiceAI

/// Records microphone audio to M4A (AAC) files via AVAssetWriter.
/// Supports mic-only and mic+system audio modes.
@Observable
final class AudioRecordingService {
    enum State {
        case idle
        case starting
        case recording
        case stopping
    }

    enum RecordingMode: String {
        case micOnly
        case micAndSystem
    }

    private(set) var state: State = .idle
    private(set) var elapsedSeconds: TimeInterval = 0

    var formattedElapsedTime: String {
        let minutes = Int(elapsedSeconds) / 60
        let seconds = Int(elapsedSeconds) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var capture: MicrophoneCapture?
    private var systemCapture: SystemAudioCapture?
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var recordingTask: Task<URL?, Never>?
    private var timerTask: Task<Void, Never>?
    private var startTime: Date?
    private(set) var outputURL: URL?

    private static let sampleRate: Double = 44100

    static let recordingsDir: URL = {
        let dir = CatalogDatabase.dataDirectory.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Error from the last recording attempt, if it failed.
    private(set) var lastError: String?

    func startRecording(deviceUID: String? = nil, mode: RecordingMode = .micOnly) {
        guard state == .idle else { return }

        // Check microphone permission before starting
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authStatus == .authorized else {
            if authStatus == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    DispatchQueue.main.async {
                        SystemPermissionStatus.shared.refresh()
                        if granted {
                            self?.startRecording(deviceUID: deviceUID, mode: mode)
                        } else {
                            self?.lastError = "Microphone access denied. Grant permission in System Settings → Privacy & Security → Microphone."
                            Log.error(Log.audio, "Microphone access denied by user")
                        }
                    }
                }
            } else {
                lastError = "Microphone access denied. Grant permission in System Settings → Privacy & Security → Microphone."
                Log.error(Log.audio, "Microphone access denied (status: \(authStatus.rawValue))")
            }
            return
        }

        let fileName = "recording-\(UUID().uuidString).m4a"
        let url = Self.recordingsDir.appendingPathComponent(fileName)
        outputURL = url

        state = .starting
        elapsedSeconds = 0
        startTime = Date()

        recordingTask = Task { [weak self] in
            guard let self else { return nil }
            let result = await self.performRecording(to: url, deviceUID: deviceUID, mode: mode)
            // If the recording ended on its own (error or stream ended)
            // rather than via stopRecording(), reset state to idle.
            await MainActor.run {
                if self.state == .recording || self.state == .starting {
                    self.timerTask?.cancel()
                    self.timerTask = nil
                    self.state = .idle
                    if result == nil {
                        self.lastError = "Recording failed. Check that a microphone is connected and accessible."
                    }
                }
            }
            return result
        }
    }

    func stopRecording() async -> URL? {
        guard state == .recording || state == .starting else { return nil }
        state = .stopping
        timerTask?.cancel()
        timerTask = nil
        capture?.stopCapture()
        systemCapture?.stopCapture()
        let url = await recordingTask?.value
        recordingTask = nil
        state = .idle
        return url
    }

    // MARK: - Private

    private func performRecording(to url: URL, deviceUID: String?, mode: RecordingMode) async -> URL? {
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
            ]

            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            writer.startWriting()
            writer.startSession(atSourceTime: .zero)

            self.assetWriter = writer
            self.writerInput = input

            // Write checkpoint for crash recovery
            RecordingCheckpointManager.save(RecordingCheckpoint(
                id: UUID(),
                audioFilePath: url.path,
                startedAt: startTime ?? Date(),
                deviceUID: deviceUID,
                mode: mode.rawValue
            ))

            let audioStream: AsyncStream<AVAudioPCMBuffer>

            switch mode {
            case .micOnly:
                let mic = MicrophoneCapture(deviceUID: deviceUID)
                self.capture = mic
                audioStream = try mic.startCapture(sampleRate: Self.sampleRate)

            case .micAndSystem:
                let mic = MicrophoneCapture(deviceUID: deviceUID)
                self.capture = mic
                let micStream = try mic.startCapture(sampleRate: Self.sampleRate)

                let sys = SystemAudioCapture()
                self.systemCapture = sys
                let sysStream = try await sys.startCapture(sampleRate: Self.sampleRate)

                let mixer = AudioMixer(sampleRate: Self.sampleRate)
                audioStream = mixer.mix(micStream: micStream, systemStream: sysStream)
            }

            // Audio engine confirmed running — transition to .recording
            await MainActor.run {
                guard self.state == .starting else { return }
                self.lastError = nil
                self.state = .recording
                self.timerTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        guard let self, let start = self.startTime, self.state == .recording else { break }
                        self.elapsedSeconds = Date().timeIntervalSince(start)
                    }
                }
            }

            var sampleOffset: Int64 = 0

            for await buffer in audioStream {
                guard state == .recording || state == .starting else { break }
                if let sampleBuffer = Self.createSampleBuffer(from: buffer, sampleOffset: sampleOffset, sampleRate: Self.sampleRate) {
                    if input.isReadyForMoreMediaData {
                        input.append(sampleBuffer)
                    }
                    sampleOffset += Int64(buffer.frameLength)
                }
            }

            input.markAsFinished()
            await writer.finishWriting()

            self.assetWriter = nil
            self.writerInput = nil
            self.capture = nil
            self.systemCapture = nil

            if writer.status == .completed {
                RecordingCheckpointManager.clear()
                return url
            } else {
                Log.error(Log.audio, "Writer failed: \(writer.error?.localizedDescription ?? "unknown")")
                RecordingCheckpointManager.clear()
                try? FileManager.default.removeItem(at: url)
                return nil
            }
        } catch {
            Log.error(Log.audio, "Recording failed: \(error)")
            RecordingCheckpointManager.clear()
            try? FileManager.default.removeItem(at: url)
            self.assetWriter = nil
            self.writerInput = nil
            self.capture?.stopCapture()
            self.capture = nil
            self.systemCapture?.stopCapture()
            self.systemCapture = nil
            return nil
        }
    }

    private static func createSampleBuffer(
        from pcmBuffer: AVAudioPCMBuffer,
        sampleOffset: Int64,
        sampleRate: Double
    ) -> CMSampleBuffer? {
        let frameCount = Int(pcmBuffer.frameLength)
        guard frameCount > 0, let floatData = pcmBuffer.floatChannelData?[0] else { return nil }

        // Convert Float32 -> Int16 for CMSampleBuffer
        let byteCount = frameCount * MemoryLayout<Int16>.size
        let data = NSMutableData(length: byteCount)!
        let int16Ptr = data.mutableBytes.assumingMemoryBound(to: Int16.self)
        for i in 0..<frameCount {
            let clamped = max(-1.0, min(1.0, floatData[i]))
            int16Ptr[i] = Int16(clamped * Float(Int16.max))
        }

        var formatDescription: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let desc = formatDescription else { return nil }

        let timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: sampleOffset, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        var timingInfo = timing
        var sizeInfo = byteCount

        let blockBuffer: CMBlockBuffer
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        ) == noErr, let blk = block else { return nil }
        blockBuffer = blk

        guard CMBlockBufferReplaceDataBytes(
            with: data.bytes,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        ) == noErr else { return nil }

        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sizeInfo,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }
}
