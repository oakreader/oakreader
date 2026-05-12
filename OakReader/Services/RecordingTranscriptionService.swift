import AVFoundation
import OakVoiceAI

/// Transcribes a recorded audio file using the on-device MLX STT model.
@Observable
final class RecordingTranscriptionService {
    enum Status: Sendable {
        case idle
        case loading
        case transcribing(Double)
        case completed(String)
        case failed(String)
    }

    private(set) var status: Status = .idle

    /// Transcribe an audio file by chunking into 30-second segments and running STT on each.
    /// Returns the concatenated transcript with timestamps.
    @MainActor
    func transcribe(audioURL: URL, sttModel: String) async throws -> String {
        status = .loading

        let provider = MLXSTTProvider(repoId: sttModel)

        // Load audio file and resample to 16kHz mono
        let audioFile = try AVAudioFile(forReading: audioURL)
        let sourceSampleRate = audioFile.processingFormat.sampleRate
        let sourceFrameCount = AVAudioFrameCount(audioFile.length)

        let targetSampleRate: Double = 16000
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionError.formatError
        }

        let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrameCount)!
        try audioFile.read(into: sourceBuffer)

        // Resample to 16kHz if needed
        let samples: [Float]
        if abs(sourceSampleRate - targetSampleRate) < 1.0 {
            guard let floatData = sourceBuffer.floatChannelData else {
                throw TranscriptionError.formatError
            }
            samples = Array(UnsafeBufferPointer(start: floatData[0], count: Int(sourceBuffer.frameLength)))
        } else {
            samples = try resample(buffer: sourceBuffer, from: sourceSampleRate, to: targetSampleRate)
        }

        // Chunk into 30-second segments
        let chunkSize = Int(targetSampleRate * 30)
        let totalSamples = samples.count
        let chunkCount = max(1, (totalSamples + chunkSize - 1) / chunkSize)

        var transcriptParts: [String] = []

        for i in 0..<chunkCount {
            let start = i * chunkSize
            let end = min(start + chunkSize, totalSamples)
            let chunkSamples = Array(samples[start..<end])

            guard let chunkFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            ) else { continue }

            let chunkBuffer = AVAudioPCMBuffer(pcmFormat: chunkFormat, frameCapacity: AVAudioFrameCount(chunkSamples.count))!
            chunkBuffer.frameLength = AVAudioFrameCount(chunkSamples.count)
            if let floatData = chunkBuffer.floatChannelData {
                chunkSamples.withUnsafeBufferPointer { ptr in
                    floatData[0].update(from: ptr.baseAddress!, count: chunkSamples.count)
                }
            }

            let progress = Double(i) / Double(chunkCount)
            status = .transcribing(progress)

            let result = try await provider.transcribe(audio: chunkBuffer)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let timestamp = formatTimestamp(seconds: Double(start) / targetSampleRate)
                transcriptParts.append("[\(timestamp)] \(text)")
            }
        }

        let transcript = transcriptParts.joined(separator: "\n")
        status = .completed(transcript)
        return transcript
    }

    private func resample(buffer: AVAudioPCMBuffer, from sourceSampleRate: Double, to targetSampleRate: Double) throws -> [Float] {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionError.formatError
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw TranscriptionError.resampleError
        }

        let ratio = targetSampleRate / sourceSampleRate
        let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: estimatedFrames) else {
            throw TranscriptionError.resampleError
        }

        var error: NSError?
        var isDone = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if isDone {
                outStatus.pointee = .noDataNow
                return nil
            }
            isDone = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            throw error
        }

        guard let floatData = outputBuffer.floatChannelData else {
            throw TranscriptionError.formatError
        }
        return Array(UnsafeBufferPointer(start: floatData[0], count: Int(outputBuffer.frameLength)))
    }

    private func formatTimestamp(seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    enum TranscriptionError: LocalizedError {
        case formatError
        case resampleError

        var errorDescription: String? {
            switch self {
            case .formatError: "Failed to create audio format"
            case .resampleError: "Failed to resample audio"
            }
        }
    }
}
