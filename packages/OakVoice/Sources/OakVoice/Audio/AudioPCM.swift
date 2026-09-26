import AVFoundation
import Foundation

/// Shared helpers for converting between provider audio payloads and
/// `AVAudioPCMBuffer`, plus a minimal multipart/form-data builder used by the
/// cloud speech-to-text providers.
enum AudioPCM {
    /// Convert raw signed 16-bit little-endian mono PCM into a Float32 buffer.
    ///
    /// This is the on-the-wire format returned by ElevenLabs (`pcm_*`),
    /// OpenAI (`response_format: pcm`, 24 kHz) and Gemini (`inlineData`, 24 kHz).
    static func bufferFromInt16PCM(_ data: Data, sampleRate: Double) -> AVAudioPCMBuffer? {
        let frameCount = data.count / 2 // Int16 == 2 bytes
        guard frameCount > 0,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let output = buffer.floatChannelData?[0] else { return nil }

        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                output[i] = Float(Int16(littleEndian: samples[i])) / 32768.0
            }
        }
        return buffer
    }

    /// Encode a Float32 PCM buffer as a 16-bit mono WAV file.
    ///
    /// Cloud STT endpoints accept WAV uploads at any sample rate, so this is
    /// used to turn a captured/loaded buffer into an uploadable payload.
    static func wavData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let sampleRate = UInt32(buffer.format.sampleRate)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(frameCount) * UInt32(blockAlign)

        var data = Data(capacity: 44 + Int(dataSize))
        func append<T>(_ value: T) where T: FixedWidthInteger {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36) + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))           // PCM fmt chunk size
        append(UInt16(1))            // audio format = PCM
        append(channels)
        append(sampleRate)
        append(byteRate)
        append(blockAlign)
        append(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        append(dataSize)

        let source = channelData[0]
        for i in 0..<frameCount {
            let clamped = max(-1.0, min(1.0, source[i]))
            append(Int16(clamped * 32767.0))
        }
        return data
    }

    /// Merge multiple PCM buffers (sharing a format) into one.
    static func merge(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let format = buffers.first?.format else { return nil }
        let total = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard total > 0,
              let merged = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let out = merged.floatChannelData
        else { return buffers.first }

        merged.frameLength = AVAudioFrameCount(total)
        var offset = 0
        for buf in buffers {
            guard let inData = buf.floatChannelData else { continue }
            let count = Int(buf.frameLength)
            memcpy(out[0].advanced(by: offset), inData[0], count * MemoryLayout<Float>.size)
            offset += count
        }
        return merged
    }
}

/// Minimal multipart/form-data body builder for file uploads.
struct MultipartFormData {
    let boundary = "OakVoice-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append("\(value)\r\n")
    }

    mutating func addFile(_ name: String, filename: String, mimeType: String, data fileData: Data) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")
    }

    func finalized() -> Data {
        var result = body
        result.append("--\(boundary)--\r\n")
        return result
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
