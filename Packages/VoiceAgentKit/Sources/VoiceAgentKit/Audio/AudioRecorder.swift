import AVFoundation

/// Manages per-turn CAF audio file writing for voice call recording.
///
/// Each turn produces up to two files:
/// - `turn-N-user.caf`: User microphone audio (written in bulk after STT)
/// - `turn-N-agent.caf`: Agent TTS audio (appended incrementally during streaming)
///
/// Files use Linear PCM format (CAF container) for lossless, appendable recording
/// with no 4GB limit. Written via `AVAudioFile` for incremental append support.
public actor AudioRecorder {
    private let callDirectory: URL
    private let audioDirectory: URL

    /// Currently open file handle for agent audio streaming (one per turn).
    private var agentAudioFile: AVAudioFile?
    private var agentAudioTurnIndex: Int = -1

    /// Tracks which turns have user/agent audio files.
    private var turnsWithUserAudio: Set<Int> = []
    private var turnsWithAgentAudio: Set<Int> = []

    public init(callDirectory: URL) {
        self.callDirectory = callDirectory
        self.audioDirectory = callDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    // MARK: - User Audio

    /// Write all accumulated speech buffers for a completed user turn.
    /// Called once after STT finishes processing the turn's audio.
    public func writeUserAudio(turnIndex: Int, buffers: [AVAudioPCMBuffer]) throws {
        guard !buffers.isEmpty else { return }
        guard let firstBuffer = buffers.first else { return }

        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        let url = audioURL(turnIndex: turnIndex, role: "user")
        let file = try AVAudioFile(forWriting: url, settings: firstBuffer.format.settings)
        for buffer in buffers {
            try file.write(from: buffer)
        }
        turnsWithUserAudio.insert(turnIndex)
    }

    // MARK: - Agent Audio

    /// Append a single TTS buffer to the agent audio file for the current turn.
    /// Called incrementally as TTS produces audio buffers during streaming.
    public func appendAgentAudio(turnIndex: Int, buffer: AVAudioPCMBuffer) throws {
        // Open a new file if we moved to a different turn
        if turnIndex != agentAudioTurnIndex {
            agentAudioFile = nil
            agentAudioTurnIndex = turnIndex

            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

            let url = audioURL(turnIndex: turnIndex, role: "agent")
            agentAudioFile = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
            turnsWithAgentAudio.insert(turnIndex)
        }

        try agentAudioFile?.write(from: buffer)
    }

    // MARK: - Lifecycle

    /// Close any open file handles. Call when the voice call ends.
    public func finalize() {
        agentAudioFile = nil
        agentAudioTurnIndex = -1
    }

    // MARK: - Query

    /// Whether user audio was recorded for a given turn.
    public func hasUserAudio(turnIndex: Int) -> Bool {
        turnsWithUserAudio.contains(turnIndex)
    }

    /// Whether agent audio was recorded for a given turn.
    public func hasAgentAudio(turnIndex: Int) -> Bool {
        turnsWithAgentAudio.contains(turnIndex)
    }

    // MARK: - Paths

    private func audioURL(turnIndex: Int, role: String) -> URL {
        audioDirectory.appendingPathComponent("turn-\(turnIndex)-\(role).caf")
    }
}
