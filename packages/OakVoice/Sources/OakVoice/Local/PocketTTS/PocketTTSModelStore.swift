import CoreML
import CryptoKit
import Foundation

/// Fetches, verifies and installs the Pocket TTS model artifacts.
///
/// Nothing ships in the app bundle. The three Core ML packages are ~292 MB, which is more than
/// a reading app should carry for an optional provider, so they are fetched the first time the
/// user selects on-device speech and cached under Application Support.
///
/// Voices are deliberately **not** part of that first fetch. Twenty-one of them would add
/// ~130 MB for files the user will mostly never select, so each is pulled on first use at
/// ~6 MB, which is fast enough to feel immediate.
///
/// Integrity: the three model zips carry pinned SHA-256 digests, checked before anything is
/// unpacked, because a truncated download otherwise surfaces as an unintelligible Core ML
/// compile failure. Voices are validated by strict parse instead — see ``voiceFile(for:)``.
public actor PocketTTSModelStore {
    public static let shared = PocketTTSModelStore()

    /// An artifact that must be present before synthesis can start.
    public enum Artifact: String, CaseIterable, Sendable {
        case promptPhase = "prompt_phase"
        case calmStateful = "calm_stateful"
        case mimiStateful = "mimi_stateful"
        case tokenizer = "tokenizer"

        /// Human-readable name for the download progress rows.
        public var displayName: String {
            switch self {
            case .promptPhase: return "Prompt encoder"
            case .calmStateful: return "Speech generator"
            case .mimiStateful: return "Audio decoder"
            case .tokenizer: return "Text tokenizer"
            }
        }

        /// Approximate download size, for the settings row.
        public var approximateBytes: Int64 {
            switch self {
            case .promptPhase: return 110_000_000
            case .calmStateful: return 161_000_000
            case .mimiStateful: return 20_000_000
            case .tokenizer: return 245_000
            }
        }

        /// Core ML packages arrive zipped and need compiling; the tokenizer is a plain file.
        var isCoreMLPackage: Bool { self != .tokenizer }

        /// SHA-256 of the bytes as downloaded, before any unpacking.
        var expectedSHA256: String {
            switch self {
            case .promptPhase:
                return "2f85b6c542da3bc8125782322e19089463787beddd866ad7de3c22525959cc7f"
            case .calmStateful:
                return "4efed58521ee32444febceb98a9331a154ed2fe7c93667d301a747b0c5a7d08d"
            case .mimiStateful:
                return "d74980e44fd8974fe0b47dd69e4e92bd980f73c110a5195293e544374282196f"
            case .tokenizer:
                return "f498428e1eafee50492f7be13dc9bfafcfc12e508cd0eb1b01c92ecd5d8c6687"
            }
        }

        /// Filename as installed on disk.
        var installedName: String {
            isCoreMLPackage ? "\(rawValue).mlmodelc" : "tokenizer.json"
        }
    }

    public enum StoreError: Error, CustomStringConvertible {
        case downloadFailed(Artifact, underlying: Error)
        case httpStatus(Artifact, Int)
        case digestMismatch(Artifact, expected: String, actual: String)
        case unpackFailed(Artifact, String)
        case compileFailed(Artifact, underlying: Error)
        case voiceDownloadFailed(String, underlying: Error)

        public var description: String {
            switch self {
            case let .downloadFailed(a, underlying):
                return "downloading \(a.displayName) failed: \(underlying)"
            case let .httpStatus(a, code):
                return "downloading \(a.displayName) failed with HTTP \(code)"
            case let .digestMismatch(a, expected, actual):
                return "\(a.displayName) failed its integrity check (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)"
            case let .unpackFailed(a, why):
                return "unpacking \(a.displayName) failed: \(why)"
            case let .compileFailed(a, underlying):
                return "compiling \(a.displayName) failed: \(underlying)"
            case let .voiceDownloadFailed(id, underlying):
                return "downloading voice \"\(id)\" failed: \(underlying)"
            }
        }
    }

    /// Progress for the settings UI: which artifact, and how far along.
    public struct Progress: Sendable {
        public let artifact: Artifact
        public let fractionCompleted: Double
        /// Index of this artifact in the batch, 1-based, for "2 of 4".
        public let step: Int
        public let totalSteps: Int
    }

    // MARK: - Hosting

    /// Base URL for the Core ML packages.
    ///
    /// Kept in one place on purpose. These are a third party's conversion of Kyutai's weights,
    /// published under CC-BY-4.0, so they can and should be mirrored to our own bucket rather
    /// than leaving an individual's Hugging Face repo on the runtime path.
    private static let coreMLBaseURL = URL(
        string: "https://huggingface.co/slaughters85j/pocket-tts-coreml/resolve/main"
    )!

    /// Base URL for Kyutai's own CC-BY-4.0 tokenizer and voice caches.
    private static let kyutaiBaseURL = URL(
        string: "https://huggingface.co/kyutai/pocket-tts-without-voice-cloning/resolve/main"
    )!

    private func remoteURL(for artifact: Artifact) -> URL {
        switch artifact {
        case .tokenizer:
            return Self.kyutaiBaseURL.appendingPathComponent("tokenizer.json")
        default:
            return Self.coreMLBaseURL.appendingPathComponent("\(artifact.rawValue).mlpackage.zip")
        }
    }

    private func remoteVoiceURL(id: String) -> URL {
        Self.kyutaiBaseURL
            .appendingPathComponent("embeddings_v3")
            .appendingPathComponent("\(id).safetensors")
    }

    // MARK: - Local layout

    private let fileManager = FileManager.default

    /// `~/Library/Application Support/OakReader/PocketTTS/`
    public nonisolated var installDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("OakReader", isDirectory: true)
            .appendingPathComponent("PocketTTS", isDirectory: true)
    }

    private nonisolated var voicesDirectory: URL {
        installDirectory.appendingPathComponent("voices", isDirectory: true)
    }

    public nonisolated func installedURL(for artifact: Artifact) -> URL {
        installDirectory.appendingPathComponent(artifact.installedName)
    }

    /// Whether every required artifact is present. The gate for offering the provider at all.
    public nonisolated var isInstalled: Bool {
        Artifact.allCases.allSatisfy { artifact in
            FileManager.default.fileExists(atPath: installedURL(for: artifact).path)
        }
    }

    /// Which artifacts still need downloading.
    public nonisolated var missingArtifacts: [Artifact] {
        Artifact.allCases.filter {
            !FileManager.default.fileExists(atPath: installedURL(for: $0).path)
        }
    }

    /// Bytes currently used on disk, for the settings row.
    public nonisolated func installedSize() -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: installDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Delete everything, models and cached voices alike.
    public func removeAll() throws {
        guard fileManager.fileExists(atPath: installDirectory.path) else { return }
        try fileManager.removeItem(at: installDirectory)
        VoiceAgentLog.ttsInfo("[PocketTTS] removed installed models")
    }

    // MARK: - Install

    /// Download, verify and install every missing artifact.
    ///
    /// Safe to call when nothing is missing: it returns immediately. Cancelling the surrounding
    /// task leaves no partial install behind, because each artifact lands in a staging
    /// directory and is only moved into place once verified.
    public func installIfNeeded(
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        let missing = missingArtifacts
        guard !missing.isEmpty else { return }

        try fileManager.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        VoiceAgentLog.ttsInfo("[PocketTTS] installing \(missing.count) artifact(s)")

        for (index, artifact) in missing.enumerated() {
            try Task.checkCancellation()
            onProgress?(Progress(artifact: artifact, fractionCompleted: 0,
                                 step: index + 1, totalSteps: missing.count))
            try await install(artifact) { fraction in
                onProgress?(Progress(artifact: artifact, fractionCompleted: fraction,
                                     step: index + 1, totalSteps: missing.count))
            }
            onProgress?(Progress(artifact: artifact, fractionCompleted: 1,
                                 step: index + 1, totalSteps: missing.count))
        }
        VoiceAgentLog.ttsInfo("[PocketTTS] install complete")
    }

    private func install(
        _ artifact: Artifact,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let staging = installDirectory.appendingPathComponent(
            "staging-\(artifact.rawValue)", isDirectory: true
        )
        // A previous crash may have left one behind.
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let downloaded = staging.appendingPathComponent("payload")
        try await download(remoteURL(for: artifact), to: downloaded, artifact: artifact,
                           onProgress: onProgress)

        let actual = try sha256(of: downloaded)
        guard actual == artifact.expectedSHA256 else {
            throw StoreError.digestMismatch(artifact, expected: artifact.expectedSHA256, actual: actual)
        }

        let destination = installedURL(for: artifact)
        try? fileManager.removeItem(at: destination)

        guard artifact.isCoreMLPackage else {
            try fileManager.moveItem(at: downloaded, to: destination)
            return
        }

        // Unzip, locate the .mlpackage, compile it to a .mlmodelc, then move that into place.
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try fileManager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try unzip(downloaded, into: unpacked, artifact: artifact)

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
        // compileModel writes to a temporary location that the system may reclaim.
        try fileManager.moveItem(at: compiled, to: destination)
    }

    // MARK: - Voices

    /// Local path for a voice, downloading it on first use.
    ///
    /// No pinned digest here. The voice set is 21 files that Kyutai may extend, and hardcoding
    /// hashes for all of them would rot. The integrity check is instead a strict parse by
    /// ``PocketTTSVoiceState``, which rejects a wrong dtype, a wrong shape, a missing layer or
    /// a short payload — a corrupt download cannot survive it.
    public func voiceFile(for voiceID: String) async throws -> URL {
        let destination = voicesDirectory.appendingPathComponent("\(voiceID).safetensors")
        if fileManager.fileExists(atPath: destination.path) { return destination }

        try fileManager.createDirectory(at: voicesDirectory, withIntermediateDirectories: true)
        let staged = voicesDirectory.appendingPathComponent("\(voiceID).partial")
        try? fileManager.removeItem(at: staged)

        do {
            let (temporary, response) = try await URLSession.shared.download(from: remoteVoiceURL(id: voiceID))
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw VoiceAgentError.ttsFailed("HTTP \(http.statusCode)")
            }
            try fileManager.moveItem(at: temporary, to: staged)
            // Parse before publishing, so a bad file never becomes the cached copy.
            _ = try PocketTTSVoiceState(contentsOf: staged)
            try fileManager.moveItem(at: staged, to: destination)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw StoreError.voiceDownloadFailed(voiceID, underlying: error)
        }
        VoiceAgentLog.ttsInfo("[PocketTTS] cached voice \(voiceID)")
        return destination
    }

    // MARK: - Plumbing

    private func download(
        _ url: URL,
        to destination: URL,
        artifact: Artifact,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw StoreError.httpStatus(artifact, http.statusCode)
            }
            let expected = response.expectedContentLength > 0
                ? Double(response.expectedContentLength)
                : Double(artifact.approximateBytes)

            // Buffer to memory in chunks so progress can be reported; the largest artifact is
            // 161 MB, which is acceptable, and the alternative (URLSession's download delegate)
            // needs a non-async bridge for no real gain here.
            var data = Data(capacity: Int(expected))
            var lastReported = 0.0
            for try await byte in bytes {
                data.append(byte)
                let fraction = min(1, Double(data.count) / expected)
                if fraction - lastReported >= 0.01 {
                    lastReported = fraction
                    onProgress(fraction)
                }
            }
            try data.write(to: destination)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.downloadFailed(artifact, underlying: error)
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

    private func unzip(_ archive: URL, into directory: URL, artifact: Artifact) throws {
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
