import AVFoundation
import OakVoice

/// Transcribes a recorded audio file using the configured cloud STT provider
/// (ElevenLabs Scribe, OpenAI, Gemini, or Fish Audio).
///
/// The file is resampled to 16 kHz mono and split into chunks small enough to
/// stay under provider upload limits, then each chunk is transcribed and the
/// results are concatenated with timestamps.
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

    /// Chunk length in seconds. 16 kHz mono 16-bit ≈ 32 KB/s, so ~5 min stays
    /// well under the smallest provider limit (OpenAI's 25 MB).
    private let chunkSeconds: Double = 300

    @MainActor
    func transcribe(audioURL: URL) async throws -> String {
        status = .loading

        guard let provider = VoiceProviderFactory.makeSTTProvider() else {
            status = .failed("No transcription provider configured")
            throw TranscriptionError.notConfigured
        }

        let targetSampleRate: Double = 16000
        let samples = try loadResampledSamples(audioURL: audioURL, sampleRate: targetSampleRate)

        let chunkSize = Int(targetSampleRate * chunkSeconds)
        let totalSamples = samples.count
        let chunkCount = max(1, (totalSamples + chunkSize - 1) / chunkSize)

        var transcriptParts: [String] = []
        for i in 0..<chunkCount {
            let start = i * chunkSize
            let end = min(start + chunkSize, totalSamples)
            guard let chunkBuffer = makeBuffer(Array(samples[start..<end]), sampleRate: targetSampleRate) else { continue }

            status = .transcribing(Double(i) / Double(chunkCount))

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

    // MARK: - Audio loading

    private func loadResampledSamples(audioURL: URL, sampleRate targetSampleRate: Double) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: audioURL)
        let sourceSampleRate = audioFile.processingFormat.sampleRate
        let frameCount = AVAudioFrameCount(audioFile.length)

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ), let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw TranscriptionError.formatError
        }
        try audioFile.read(into: sourceBuffer)

        if abs(sourceSampleRate - targetSampleRate) < 1.0 {
            guard let data = sourceBuffer.floatChannelData else { throw TranscriptionError.formatError }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(sourceBuffer.frameLength)))
        }
        return try resample(buffer: sourceBuffer, from: sourceSampleRate, to: targetSampleRate)
    }

    private func makeBuffer(_ samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let data = buffer.floatChannelData {
            samples.withUnsafeBufferPointer { ptr in
                data[0].update(from: ptr.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    private func resample(buffer: AVAudioPCMBuffer, from sourceSampleRate: Double, to targetSampleRate: Double) throws -> [Float] {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
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
        if let error { throw error }

        guard let data = outputBuffer.floatChannelData else { throw TranscriptionError.formatError }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(outputBuffer.frameLength)))
    }

    private func formatTimestamp(seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    enum TranscriptionError: LocalizedError {
        case notConfigured
        case formatError
        case resampleError

        var errorDescription: String? {
            switch self {
            case .notConfigured: "No transcription provider is configured. Add a voice provider in AI settings."
            case .formatError: "Failed to create audio format"
            case .resampleError: "Failed to resample audio"
            }
        }
    }
}
