import AVFoundation
import CryptoKit
import Foundation

/// Disk cache for synthesized TTS audio with a 60-minute TTL.
///
/// Keyed by text content + voice configuration, so replaying the same sentence
/// with the same voice settings returns instantly from cache.
actor TTSAudioCache {
    static let shared = TTSAudioCache()

    private let cacheDirectory: URL
    private let ttl: TimeInterval = 60 * 60 // 60 minutes

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = caches.appendingPathComponent("tts", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Load cached audio as an AsyncThrowingStream of buffers for playback.
    /// Returns `nil` if no valid (non-expired) cache entry exists.
    func loadStream(text: String, configKey: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>? {
        let url = fileURL(for: text, configKey: configKey)
        guard FileManager.default.fileExists(atPath: url.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < ttl
        else {
            // Expired or missing — clean up stale file if present
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        return AsyncThrowingStream { continuation in
            do {
                let file = try AVAudioFile(forReading: url)
                let format = file.processingFormat
                let frameCount = AVAudioFrameCount(file.length)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                    continuation.finish(throwing: TTSCacheError.bufferAllocationFailed)
                    return
                }
                try file.read(into: buffer)
                continuation.yield(buffer)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Save audio buffers to the cache.
    func store(buffers: [AVAudioPCMBuffer], text: String, configKey: String) {
        guard let first = buffers.first else { return }
        let url = fileURL(for: text, configKey: configKey)
        do {
            let file = try AVAudioFile(forWriting: url, settings: first.format.settings)
            for buffer in buffers {
                try file.write(from: buffer)
            }
            Log.debug(Log.voice, "Cached TTS audio for: \(text.prefix(50))")
        } catch {
            Log.error(Log.voice, "Failed to cache TTS audio: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Remove all expired cache entries.
    func cleanExpired() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for file in files where file.pathExtension == "wav" {
            if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
               let modified = values.contentModificationDate,
               Date().timeIntervalSince(modified) >= ttl
            {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Private

    private func fileURL(for text: String, configKey: String) -> URL {
        let input = "\(configKey)|\(text)"
        let hash = SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return cacheDirectory.appendingPathComponent("\(hash).wav")
    }

    private enum TTSCacheError: LocalizedError {
        case bufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .bufferAllocationFailed:
                return "Failed to allocate audio buffer for cached TTS file"
            }
        }
    }
}

// MARK: - Buffer collector for caching during streaming playback

/// Collects audio buffers during streaming synthesis so they can be persisted to cache
/// after playback completes.
actor TTSBufferCollector {
    private(set) var buffers: [AVAudioPCMBuffer] = []

    func append(_ buffer: AVAudioPCMBuffer) {
        buffers.append(buffer)
    }
}
