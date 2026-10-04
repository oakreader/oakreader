import CoreML
import CryptoKit
import Foundation

/// Owns everything about getting Pocket TTS files onto disk, and nothing else.
///
/// This is the only type here that touches the network. It hands back
/// ``PocketTTSAssetPaths``, so the inference layer above never learns that downloading exists
/// and can be exercised against any directory of files.
///
/// Nothing ships in the app bundle. The three Core ML packages total ~292 MB, which is more
/// than a reading app should carry for an optional provider, so they are fetched on first use
/// and cached under Application Support.
///
/// Voices are deliberately not part of that first fetch. All 21 would add ~130 MB of files most
/// readers never select, so each is pulled on demand at ~6 MB.
public actor PocketTTSAssetStore {
    public static let shared = PocketTTSAssetStore()

    /// Progress for the settings UI.
    public struct Progress: Sendable {
        public let artifact: PocketTTSArtifact
        public let fractionCompleted: Double
        /// 1-based position in the batch, for "2 of 4".
        public let step: Int
        public let totalSteps: Int
    }

    public enum StoreError: Error, CustomStringConvertible {
        case downloadFailed(String, underlying: Error)
        case httpStatus(String, Int)
        case digestMismatch(PocketTTSArtifact, expected: String, actual: String)
        case unpackFailed(PocketTTSArtifact, String)
        case compileFailed(PocketTTSArtifact, underlying: Error)
        case corruptVoice(String, underlying: Error)

        public var description: String {
            switch self {
            case let .downloadFailed(what, underlying):
                return "downloading \(what) failed: \(underlying)"
            case let .httpStatus(what, code):
                return "downloading \(what) failed with HTTP \(code)"
            case let .digestMismatch(artifact, expected, actual):
                return "\(artifact.displayName) failed its integrity check "
                    + "(expected \(expected.prefix(12))…, got \(actual.prefix(12))…)"
            case let .unpackFailed(artifact, why):
                return "unpacking \(artifact.displayName) failed: \(why)"
            case let .compileFailed(artifact, underlying):
                return "compiling \(artifact.displayName) failed: \(underlying)"
            case let .corruptVoice(id, underlying):
                return "voice \"\(id)\" did not parse after download: \(underlying)"
            }
        }
    }

    private let fileManager = FileManager.default

    /// Install directory. Immutable and `Sendable`, so it is readable without isolation.
    public nonisolated let installDirectory: URL

    /// - Parameter root: install directory. Defaults to Application Support; tests pass a
    ///   temporary directory.
    public init(root: URL? = nil) {
        self.installDirectory = root ?? Self.defaultRoot
    }

    /// `~/Library/Application Support/OakReader/PocketTTS/`
    private static var defaultRoot: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("OakReader", isDirectory: true)
            .appendingPathComponent("PocketTTS", isDirectory: true)
    }

    private var voicesDirectory: URL {
        installDirectory.appendingPathComponent("voices", isDirectory: true)
    }

    private func location(of artifact: PocketTTSArtifact) -> URL {
        installDirectory.appendingPathComponent(artifact.installedName)
    }

    // MARK: - Status

    /// Artifacts still to download. Empty means synthesis can start.
    public func missingArtifacts() -> [PocketTTSArtifact] {
        PocketTTSArtifact.allCases.filter {
            !fileManager.fileExists(atPath: location(of: $0).path)
        }
    }

    public func isInstalled() -> Bool { missingArtifacts().isEmpty }

    /// Bytes on disk, models and cached voices together.
    public func installedSize() -> Int64 {
        guard let walker = fileManager.enumerator(
            at: installDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Delete every installed file, models and voices alike.
    public func removeAll() throws {
        guard fileManager.fileExists(atPath: installDirectory.path) else { return }
        try fileManager.removeItem(at: installDirectory)
        VoiceAgentLog.ttsInfo("[PocketTTS] removed installed models")
    }

    // MARK: - Install

    /// Install anything missing, then report where everything lives.
    ///
    /// Idempotent, so callers may invoke it before every utterance. Cancelling leaves no
    /// partial install: each artifact is verified in a staging directory before being moved
    /// into place.
    public func ensureInstalled(
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> PocketTTSAssetPaths {
        let missing = missingArtifacts()
        if !missing.isEmpty {
            try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
            VoiceAgentLog.ttsInfo("[PocketTTS] installing \(missing.count) artifact(s)")

            let totalSteps = missing.count
            for (index, artifact) in missing.enumerated() {
                try Task.checkCancellation()
                // Declared @Sendable up front: the installer hands this across a download
                // task boundary, and every capture here is already Sendable.
                let report: @Sendable (Double) -> Void = { fraction in
                    onProgress?(Progress(
                        artifact: artifact, fractionCompleted: fraction,
                        step: index + 1, totalSteps: totalSteps
                    ))
                }
                report(0)
                try await install(artifact, onProgress: report)
                report(1)
            }
            VoiceAgentLog.ttsInfo("[PocketTTS] install complete")
        }
        return PocketTTSAssetPaths(
            promptPhase: location(of: .promptPhase),
            speechGenerator: location(of: .speechGenerator),
            audioDecoder: location(of: .audioDecoder),
            tokenizer: location(of: .tokenizer)
        )
    }

    private func install(
        _ artifact: PocketTTSArtifact,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let staging = installDirectory.appendingPathComponent("staging-\(artifact.rawValue)", isDirectory: true)
        // A previous crash may have left one behind.
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let payload = staging.appendingPathComponent("payload")
        try await download(
            artifact.remoteURL, to: payload,
            describedAs: artifact.displayName,
            expectedBytes: artifact.approximateBytes,
            onProgress: onProgress
        )

        let digest = try sha256(of: payload)
        guard digest == artifact.expectedSHA256 else {
            throw StoreError.digestMismatch(
                artifact, expected: artifact.expectedSHA256, actual: digest
            )
        }

        let destination = location(of: artifact)
        try? fileManager.removeItem(at: destination)

        guard artifact.needsCompilation else {
            try fileManager.moveItem(at: payload, to: destination)
            return
        }

        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try unzip(payload, into: unpacked, artifact: artifact)

        guard let package = try fileManager
            .contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "mlpackage" })
        else {
            throw StoreError.unpackFailed(artifact, "no .mlpackage inside the archive")
        }

        let compiled: URL
        do {
            compiled = try await MLModel.compileModel(at: package)
        } catch {
            throw StoreError.compileFailed(artifact, underlying: error)
        }
        // compileModel writes somewhere temporary that the system may reclaim.
        try fileManager.moveItem(at: compiled, to: destination)
    }

    // MARK: - Voices

    /// Local path for a voice, downloading it on first use.
    ///
    /// No pinned digest. Kyutai may extend the voice set, and hardcoded hashes for 21 files
    /// would rot. Integrity is enforced by parsing the file through ``PocketTTSVoiceState``
    /// before it is published into the cache: that rejects a wrong dtype, a wrong shape, a
    /// missing layer or a short payload, which a corrupt download cannot survive.
    public func voiceFile(for voiceID: String) async throws -> URL {
        let destination = voicesDirectory.appendingPathComponent("\(voiceID).safetensors")
        if fileManager.fileExists(atPath: destination.path) { return destination }

        try fileManager.createDirectory(at: voicesDirectory, withIntermediateDirectories: true)
        let staged = voicesDirectory.appendingPathComponent("\(voiceID).partial")
        try? fileManager.removeItem(at: staged)

        do {
            try await download(
                PocketTTSArtifact.remoteVoiceURL(id: voiceID), to: staged,
                describedAs: "voice \(voiceID)",
                expectedBytes: 7_000_000,
                onProgress: { _ in }
            )
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }

        do {
            _ = try PocketTTSVoiceState(contentsOf: staged)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw StoreError.corruptVoice(voiceID, underlying: error)
        }

        try fileManager.moveItem(at: staged, to: destination)
        VoiceAgentLog.ttsInfo("[PocketTTS] cached voice \(voiceID)")
        return destination
    }

    // MARK: - Plumbing

    private func download(
        _ url: URL,
        to destination: URL,
        describedAs description: String,
        expectedBytes: Int64,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw StoreError.httpStatus(description, http.statusCode)
            }
            let total = response.expectedContentLength > 0
                ? Double(response.expectedContentLength)
                : Double(expectedBytes)

            // Buffered in memory so progress can be reported; the largest artifact is 161 MB,
            // and the delegate-based alternative needs a non-async bridge for no real gain.
            var data = Data(capacity: Int(total))
            var lastReported = 0.0
            for try await byte in bytes {
                data.append(byte)
                let fraction = min(1, Double(data.count) / total)
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    onProgress(fraction)
                }
            }
            try data.write(to: destination)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.downloadFailed(description, underlying: error)
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func unzip(_ archive: URL, into directory: URL, artifact: PocketTTSArtifact) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            throw StoreError.unpackFailed(artifact, "\(error)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(
                data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            ) ?? "ditto exited \(process.terminationStatus)"
            throw StoreError.unpackFailed(artifact, message)
        }
    }
}
